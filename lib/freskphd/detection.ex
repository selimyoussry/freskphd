defmodule Freskphd.Detection do
  @moduledoc """
  Runs the automated first pass on a fresk and persists the result:

    1. `pyvision` (OpenCV sidecar) — precise card/section boxes, fill colors and a
       downscaled display image.
    2. `Freskphd.Vision` (Mistral) — the text of each card/section crop, and the
       full-image arrow graph (source -> target by text, plus style and color).
    3. reconcile — attach VLM text to CV boxes, and turn VLM arrows into links by
       matching endpoint text to card text.

  Runs in the background under `Freskphd.TaskSupervisor`, broadcasting status on
  the fresk's PubSub topic. Degrades to CV-only when no Mistral key is configured.
  """

  require Logger

  alias Freskphd.{Fresks, Vision}
  alias Freskphd.Fresks.Fresk

  @pubsub Freskphd.PubSub

  @doc "PubSub topic carrying detection progress for a fresk."
  def topic(fresk_id), do: "fresk:#{fresk_id}"

  @index_topic "fresks"

  @doc "PubSub topic the fresks index subscribes to for status changes."
  def index_topic, do: @index_topic

  @doc "Starts detection for a fresk in the background. Returns the task ref."
  def detect_async(%Fresk{} = fresk) do
    Task.Supervisor.start_child(Freskphd.TaskSupervisor, fn -> run(fresk) end)
  end

  @doc "Runs detection synchronously. Returns `{:ok, fresk}` or `{:error, reason}`."
  def run(%Fresk{} = fresk) do
    {:ok, fresk} = Fresks.set_status(fresk, "processing")
    progress(fresk, :started, "Starting detection…")

    try do
      do_run(fresk)
    rescue
      e ->
        Logger.error("Detection crashed for fresk #{fresk.id}: #{Exception.message(e)}")
        Fresks.set_status(fresk, "failed", Exception.message(e))
        progress(fresk, :failed, "Detection failed: #{Exception.message(e)}")
        {:error, e}
    end
  end

  defp do_run(fresk) do
    original = Fresks.get_image(fresk.id, "original") || raise "fresk #{fresk.id} has no image"

    progress(fresk, :opencv, "Analyzing image geometry with OpenCV…")
    det = run_sidecar(original.data)
    nc = length(det["cards"])
    ns = length(det["sections"])
    progress(fresk, :opencv, "OpenCV found #{nc} cards and #{ns} sections")

    {:ok, fresk} = store_display(fresk, det)

    card_texts =
      read_crops(Enum.map(det["cards"], & &1["crop_b64"]), fresk, :cards, "card")

    section_titles =
      read_crops(Enum.map(det["sections"], & &1["title_crop_b64"]), fresk, :sections, "section")

    progress(fresk, :arrows, "Reading the arrow graph with Mistral…")
    graph = read_graph(det["display"]["png_b64"])

    cards = build_cards(det["cards"], card_texts, fresk)
    sections = build_sections(det["sections"], section_titles, cards, fresk)
    link_specs = build_links(graph["arrows"] || [], cards, sections)

    progress(fresk, :saving, "Saving #{length(cards)} cards and #{length(link_specs)} arrows…")
    {:ok, _} = Fresks.replace_detection(fresk, cards, sections, link_specs)
    {:ok, fresk} = Fresks.set_status(fresk, "review")

    progress(fresk, :done, "Done — #{length(cards)} cards, #{length(link_specs)} arrows")
    {:ok, fresk}
  end

  # --- pyvision sidecar ---------------------------------------------------

  defp run_sidecar(bytes) do
    cfg = Application.fetch_env!(:freskphd, :detection)
    tmp = Path.join(System.tmp_dir!(), "fresk-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, bytes)

    try do
      args =
        ["run", "--project", cfg[:pyvision_dir], "pyvision", "detect", tmp] ++
          ["--crops", "--display", "--max-dim", to_string(cfg[:detect_max_dim])]

      case System.cmd(cfg[:uv_bin], args, stderr_to_stdout: false) do
        {out, 0} -> Jason.decode!(out)
        {out, code} -> raise "pyvision exited #{code}: #{String.slice(out, 0, 500)}"
      end
    after
      File.rm(tmp)
    end
  end

  defp store_display(fresk, det) do
    display = det["display"]
    png = Base.decode64!(display["png_b64"])

    {:ok, _img} =
      Fresks.put_image(fresk, "display", %{
        content_type: "image/png",
        width: display["width"],
        height: display["height"],
        byte_size: byte_size(png),
        data: png
      })

    Fresks.update_fresk(fresk, %{
      "image_width" => det["image"]["width"],
      "image_height" => det["image"]["height"]
    })
  end

  # --- VLM (graceful degradation when unconfigured / on error) ------------

  defp read_crops([], _fresk, _stage, _noun), do: []

  defp read_crops(crops, fresk, stage, noun) do
    progress(fresk, stage, "Reading #{noun} text with Mistral… (0/#{length(crops)})")

    on_progress = fn done, total ->
      progress(fresk, stage, "Reading #{noun} text with Mistral… (#{done}/#{total})")
    end

    case Vision.read_crops(crops, on_progress) do
      {:ok, texts} ->
        texts

      {:error, reason} ->
        Logger.warning("Vision.read_crops failed (#{inspect(reason)}); leaving text blank")
        List.duplicate("", length(crops))
    end
  end

  defp read_graph(png_b64) do
    case Vision.read_graph(png_b64) do
      {:ok, graph} ->
        graph

      {:error, reason} ->
        Logger.warning("Vision.read_graph failed (#{inspect(reason)}); no arrows")
        %{"arrows" => [], "sections" => [], "cards" => [], "title" => ""}
    end
  end

  # --- reconciliation -----------------------------------------------------

  defp build_cards(cv_cards, texts, fresk) do
    texts = pad(texts, length(cv_cards))

    Enum.zip(cv_cards, texts)
    |> Enum.map(fn {c, text} ->
      [x1, y1, x2, y2] = c["box"]

      %{
        "type" => "card",
        "title" => blank_to_nil(text),
        "x1" => x1,
        "y1" => y1,
        "x2" => x2,
        "y2" => y2,
        "fresk_width" => fresk.image_width || 1.0,
        "color" => c["fill_hex"],
        "category" => c["color_name"],
        "confidence" => c["confidence"]
      }
    end)
  end

  defp build_sections(cv_sections, titles, cards, fresk) do
    titles = pad(titles, length(cv_sections))
    card_texts = MapSet.new(cards, &norm(&1["title"]))

    Enum.zip(cv_sections, titles)
    |> Enum.map(fn {s, title} ->
      [x1, y1, x2, y2] = s["box"]

      # A section's title strip can catch a card sitting at the top of the box;
      # if the read text is actually a card name, drop it (the reviewer fills it).
      title = if MapSet.member?(card_texts, norm(title)), do: nil, else: blank_to_nil(title)

      %{
        "type" => "section",
        "title" => title,
        "x1" => x1,
        "y1" => y1,
        "x2" => x2,
        "y2" => y2,
        "fresk_width" => fresk.image_width || 1.0,
        "confidence" => s["confidence"]
      }
    end)
  end

  # Turn VLM arrows (source/target by card text) into index-based link specs
  # against the combined `cards ++ sections` annotation list.
  defp build_links(arrows, cards, sections) do
    annotations = cards ++ sections

    index_by_text =
      annotations
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {a, i}, acc ->
        case norm(a["title"]) do
          "" -> acc
          key -> Map.put_new(acc, key, i)
        end
      end)

    arrows
    |> Enum.flat_map(fn arrow ->
      src = match_index(index_by_text, arrow["source"])
      tgt = match_index(index_by_text, arrow["target"])

      if src && tgt && src != tgt do
        [
          {src, tgt,
           %{
             "line_style" => arrow["style"],
             "color" => arrow["color"],
             "confidence" => 0.6
           }}
        ]
      else
        []
      end
    end)
  end

  defp match_index(index_by_text, text) do
    key = norm(text)

    cond do
      key == "" -> nil
      Map.has_key?(index_by_text, key) -> index_by_text[key]
      true -> fuzzy_match(index_by_text, key)
    end
  end

  # Fall back to a substring match when exact normalized text doesn't line up.
  defp fuzzy_match(index_by_text, key) do
    Enum.find_value(index_by_text, fn {k, i} ->
      if String.contains?(k, key) or String.contains?(key, k), do: i
    end)
  end

  # --- helpers ------------------------------------------------------------

  defp norm(nil), do: ""

  defp norm(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9 ]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp pad(list, n) do
    list ++ List.duplicate("", max(0, n - length(list)))
  end

  @doc "Ordered detection stages, for rendering a progress checklist."
  def stages, do: [:opencv, :cards, :sections, :arrows, :saving, :done]

  defp progress(%Fresk{id: id}, stage, text) do
    Phoenix.PubSub.broadcast(@pubsub, topic(id), {:detection, stage, text})
    Phoenix.PubSub.broadcast(@pubsub, @index_topic, {:fresk_updated, id})
  end
end
