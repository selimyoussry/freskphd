defmodule Freskphd.Vision do
  @moduledoc """
  Mistral vision client. Reads the printed text the OpenCV sidecar can't.

  `read_crops/1` returns one text per card/section crop, in the SAME order as the
  input list (batched multi-image calls give a direct index → text mapping).

  Requests use structured outputs (`response_format: json_schema`), so the model
  is forced to return valid JSON matching our schema. (Arrows are drawn by hand,
  so there is no arrow-reading entry point.)
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

  # The model may occasionally return the wrong count; align to n defensively.
  defp pad(texts, n) do
    texts = texts |> Enum.map(&to_string/1) |> Enum.take(n)
    texts ++ List.duplicate("", max(0, n - length(texts)))
  end

  defp config, do: Application.fetch_env!(:freskphd, :vision)
end
