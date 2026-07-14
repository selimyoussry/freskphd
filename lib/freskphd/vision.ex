defmodule Freskphd.Vision do
  @moduledoc """
  Mistral vision client. Reads the text the OpenCV sidecar can't, and the
  semantic arrow graph that CV geometry alone can't resolve.

  Two entry points, both taking base64-encoded PNG bytes:

    * `read_crops/1` — one text per card/section crop, in the SAME order as the
      input list (batched multi-image calls give a direct index → text mapping).
    * `read_graph/1` — a full-image structured pass returning the fresk title,
      cards (text + color), sections (title + parent) and arrows (source →
      target by text, plus line style and color).

  All requests use structured outputs (`response_format: json_schema`), so the
  model is forced to return valid JSON matching our schema.
  """

  require Logger

  @doc "Whether a Mistral API key is configured (detection can run CV-only without one)."
  def configured?, do: is_binary(config()[:api_key]) and config()[:api_key] != ""

  @doc """
  Reads the printed text of each crop. Returns `{:ok, texts}` where `texts` has
  one entry per input crop (in order). Empty input returns `{:ok, []}`.

  `on_progress` is an optional `fn done, total -> :ok end` called after each
  batch, so callers can report progress on the slow text-reading step.
  """
  def read_crops(crops_b64, on_progress \\ nil)

  def read_crops([], _on_progress), do: {:ok, []}

  def read_crops(crops_b64, on_progress) when is_list(crops_b64) do
    chunk = config()[:max_crops_per_call] || 8
    total = length(crops_b64)

    crops_b64
    |> Enum.chunk_every(chunk)
    |> Enum.reduce_while({:ok, [], 0}, fn batch, {:ok, acc, done} ->
      case read_crop_batch(batch) do
        {:ok, texts} ->
          done = done + length(batch)
          if is_function(on_progress, 2), do: on_progress.(done, total)
          {:cont, {:ok, acc ++ pad(texts, length(batch)), done}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, texts, _done} -> {:ok, texts}
      other -> other
    end
  end

  defp read_crop_batch(batch) do
    instruction =
      "Each image is one card or section cropped from a Climate-Fresk-style " <>
        "diagram. Return the exact printed text of each image, in order, as JSON " <>
        "{\"texts\": [...]} with exactly one string per image. Preserve accents; " <>
        "use \"\" for an image with no legible text."

    content =
      [%{type: "text", text: instruction}] ++ Enum.map(batch, &image_part/1)

    schema = %{
      type: "object",
      additionalProperties: false,
      properties: %{texts: %{type: "array", items: %{type: "string"}}},
      required: ["texts"]
    }

    with {:ok, %{"texts" => texts}} <- chat(content, "crop_texts", schema) do
      {:ok, texts}
    end
  end

  @doc """
  Full-image structured pass. `image_b64` is the base64 PNG of the (downscaled)
  fresk. Returns `{:ok, %{title, cards, sections, arrows}}`.
  """
  def read_graph(image_b64) when is_binary(image_b64) do
    instruction =
      "This is a Climate-Fresk-style diagram of cards linked by arrows. Extract:\n" <>
        "- title: the big free-standing title text (\"\" if none).\n" <>
        "- cards: every small filled colored rectangle — its exact printed text and fill color (hex).\n" <>
        "- sections: every large rectangle that GROUPS cards — its title, and the title of its " <>
        "parent section if it is nested inside another (null otherwise).\n" <>
        "- arrows: every connector — the source card text, the target card text (following the " <>
        "arrowhead), the line style (solid or dashed) and the line color (hex). Use exact card text."

    content = [%{type: "text", text: instruction}, image_part(image_b64)]

    schema = %{
      type: "object",
      additionalProperties: false,
      properties: %{
        title: %{type: "string"},
        cards: array_of(%{text: :string, color: :string}, ["text", "color"]),
        sections:
          array_of(%{title: :string, parent_title: %{type: ["string", "null"]}}, ["title"]),
        arrows:
          array_of(
            %{
              source: :string,
              target: :string,
              style: %{type: "string", enum: ["solid", "dashed"]},
              color: :string
            },
            ["source", "target", "style", "color"]
          )
      },
      required: ["title", "cards", "sections", "arrows"]
    }

    chat(content, "fresk_graph", schema)
  end

  # --- HTTP ---------------------------------------------------------------

  defp chat(content, schema_name, schema) do
    cfg = config()

    if not configured?() do
      {:error, :not_configured}
    else
      body = %{
        model: cfg[:model],
        temperature: 0,
        messages: [%{role: "user", content: content}],
        response_format: %{
          type: "json_schema",
          json_schema: %{name: schema_name, strict: true, schema: schema}
        }
      }

      url = String.trim_trailing(cfg[:base_url], "/") <> "/chat/completions"

      opts =
        [
          auth: {:bearer, cfg[:api_key]},
          json: body,
          receive_timeout: cfg[:receive_timeout] || 180_000,
          retry: :transient,
          max_retries: 2
        ]
        |> maybe_put(:plug, cfg[:plug])

      case Req.post(url, opts) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => raw}} | _]}}} ->
          decode(raw)

        {:ok, %{status: status, body: body}} ->
          Logger.error("Vision API #{status}: #{inspect(body)}")
          {:error, {:http, status}}

        {:error, reason} ->
          Logger.error("Vision API transport error: #{inspect(reason)}")
          {:error, {:transport, reason}}
      end
    end
  end

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode(map) when is_map(map), do: {:ok, map}

  # --- helpers ------------------------------------------------------------

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp image_part(b64), do: %{type: "image_url", image_url: "data:image/png;base64,#{b64}"}

  defp array_of(props, required) do
    props =
      Map.new(props, fn
        {k, atom} when is_atom(atom) -> {k, %{type: Atom.to_string(atom)}}
        {k, spec} -> {k, spec}
      end)

    %{
      type: "array",
      items: %{type: "object", additionalProperties: false, properties: props, required: required}
    }
  end

  # The model may occasionally return the wrong count; align to n defensively.
  defp pad(texts, n) do
    texts = texts |> Enum.map(&to_string/1) |> Enum.take(n)
    texts ++ List.duplicate("", max(0, n - length(texts)))
  end

  defp config, do: Application.fetch_env!(:freskphd, :vision)
end
