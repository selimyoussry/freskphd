defmodule Mix.Tasks.Freskphd.ImportExports do
  @shortdoc "Imports fresk PNG exports from a directory and runs detection"
  @moduledoc """
  Imports every `*.png` under a directory (default `data/fresk_exports`) as a
  fresk, storing the image bytes in the DB, then runs the automated detection
  pass on each.

      mix freskphd.import_exports [DIR] [--no-detect] [--reset]

    * `--no-detect`  only import the images, skip detection
    * `--reset`      delete all existing fresks first

  Filenames are expected as `NNN_Title_DDMMYYYY.png`.
  """
  use Mix.Task

  alias Freskphd.{Detection, Fresks}

  @impl true
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv, switches: [detect: :boolean, reset: :boolean])

    Mix.Task.run("app.start")

    dir = List.first(args) || "data/fresk_exports"
    detect? = Keyword.get(opts, :detect, true)

    if Keyword.get(opts, :reset, false) do
      Enum.each(Fresks.list_fresks(), &Fresks.delete_fresk/1)
      Mix.shell().info("Deleted existing fresks.")
    end

    files = dir |> Path.join("*.png") |> Path.wildcard() |> Enum.sort()

    if files == [] do
      Mix.shell().error("No PNG files found in #{dir}")
    else
      Mix.shell().info(
        "Importing #{length(files)} fresk(s) from #{dir}#{if detect?, do: " with detection", else: ""}…"
      )

      Enum.each(files, &import_file(&1, detect?))
      Mix.shell().info("Done.")
    end
  end

  defp import_file(path, detect?) do
    {title, dt} = parse_filename(Path.basename(path, ".png"))
    bytes = File.read!(path)

    {:ok, fresk} =
      Fresks.create_fresk_with_image(
        %{"title" => title, "dt" => dt},
        %{data: bytes, content_type: "image/png"}
      )

    Mix.shell().info("  ##{fresk.id} #{title}")

    if detect? do
      case Detection.run(fresk) do
        {:ok, f} ->
          f = Fresks.get_fresk!(f.id)
          Mix.shell().info("     -> #{length(f.annotations)} annotations [#{f.status}]")

        {:error, _} ->
          Mix.shell().error("     -> detection failed")
      end
    end
  end

  # "003_Cycle de la connaissance..._10012024" -> {title, "2024-01-10"}
  defp parse_filename(name) do
    parts = String.split(name, "_")

    {title, dt} =
      case parts do
        [_num | rest] when rest != [] ->
          {date_part, title_parts} = List.pop_at(rest, -1)
          {Enum.join(title_parts, " "), parse_date(date_part)}

        _ ->
          {name, nil}
      end

    {String.trim(title) |> nil_if_blank() || name, dt || iso_today()}
  end

  defp parse_date(<<d::binary-2, m::binary-2, y::binary-4>>), do: "#{y}-#{m}-#{d}"
  defp parse_date(_), do: nil

  defp iso_today, do: Date.utc_today() |> Date.to_iso8601()

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s
end
