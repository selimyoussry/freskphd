defmodule Freskphd.Fresks do
  @moduledoc """
  The Fresks context: fresks, their annotations (cards/sections), the arrows
  linking annotations, plus the geometry used to nest cards under sections and
  the flattened XLSX export.
  """

  import Ecto.Query, warn: false

  alias Freskphd.Repo
  alias Freskphd.Fresks.{Annotation, Fresk, FreskImage, Link}

  @arrow_kinds ["dependency", "positive_influence", "negative_influence"]

  def arrow_kinds, do: @arrow_kinds

  ## Fresks

  @doc "Lists fresks (most recent first) with annotations and links preloaded."
  def list_fresks do
    Fresk
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Repo.preload(annotations: [links: :target_annotation])
  end

  @doc "Fetches a single fresk with annotations and links preloaded."
  def get_fresk!(id) do
    Fresk
    |> Repo.get!(id)
    |> Repo.preload(annotations: [links: :target_annotation])
  end

  def create_fresk(attrs), do: %Fresk{} |> Fresk.changeset(attrs) |> Repo.insert()

  def update_fresk(%Fresk{} = fresk, attrs),
    do: fresk |> Fresk.changeset(attrs) |> Repo.update()

  def delete_fresk(%Fresk{} = fresk), do: Repo.delete(fresk)

  @doc "Updates a fresk's status (and optionally its detection_error)."
  def set_status(%Fresk{} = fresk, status, error \\ nil) do
    fresk
    |> Fresk.changeset(%{"status" => status, "detection_error" => error})
    |> Repo.update()
  end

  ## Images (stored as BLOBs in the DB)

  @doc """
  Creates a fresk together with its stored original image bytes, in a transaction.
  `image` is `%{data: binary, content_type: string}`. Returns `{:ok, fresk}`.
  """
  def create_fresk_with_image(attrs, %{data: bytes} = image) do
    Repo.transaction(fn ->
      with {:ok, fresk} <- create_fresk(attrs),
           {:ok, _} <-
             put_image(fresk, "original", %{
               content_type: Map.get(image, :content_type, "image/png"),
               byte_size: byte_size(bytes),
               data: bytes
             }) do
        fresk
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Inserts or replaces the `kind` image (`\"original\"`/`\"display\"`) for a fresk."
  def put_image(%Fresk{id: fresk_id}, kind, attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"fresk_id" => fresk_id, "kind" => kind})

    %FreskImage{}
    |> FreskImage.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:content_type, :width, :height, :byte_size, :data, :updated_at]},
      conflict_target: [:fresk_id, :kind]
    )
  end

  @doc "Fetches a fresk image (with bytes) by fresk id and kind, or nil."
  def get_image(fresk_id, kind), do: Repo.get_by(FreskImage, fresk_id: fresk_id, kind: kind)

  ## Detection persistence

  @doc """
  Replaces all auto-detected annotations/links of a fresk with a freshly detected
  set, in a single transaction. `cards` and `sections` are attribute maps; `links`
  is a list of `{source_key, target_key, attrs}` where the keys index into the
  combined annotation list by insertion order.
  """
  def replace_detection(%Fresk{} = fresk, cards, sections, link_specs) do
    Repo.transaction(fn ->
      Repo.delete_all(from(a in Annotation, where: a.fresk_id == ^fresk.id))

      annotations =
        Enum.map(cards ++ sections, fn attrs ->
          {:ok, ann} =
            create_annotation(Map.merge(attrs, %{"fresk_id" => fresk.id, "source" => "auto"}))

          ann
        end)

      by_key = annotations |> Enum.with_index() |> Map.new(fn {a, i} -> {i, a} end)

      Enum.each(link_specs, fn {src_i, tgt_i, attrs} ->
        with %Annotation{} = src <- Map.get(by_key, src_i),
             %Annotation{} = tgt <- Map.get(by_key, tgt_i) do
          create_link(
            Map.merge(attrs, %{
              "source_annotation_id" => src.id,
              "target_annotation_id" => tgt.id,
              "origin" => "auto"
            })
          )
        end
      end)

      annotations
    end)
  end

  ## Annotations

  def get_annotation!(id), do: Repo.get!(Annotation, id)

  def create_annotation(attrs), do: %Annotation{} |> Annotation.changeset(attrs) |> Repo.insert()

  def update_annotation(%Annotation{} = annotation, attrs),
    do: annotation |> Annotation.changeset(attrs) |> Repo.update()

  def delete_annotation(%Annotation{} = annotation), do: Repo.delete(annotation)

  ## Links (arrows)

  def get_link!(id), do: Repo.get!(Link, id)

  def create_link(attrs), do: %Link{} |> Link.changeset(attrs) |> Repo.insert()

  def delete_link(%Link{} = link), do: Repo.delete(link)

  ## Projection

  @doc """
  Decorates a fresk's annotations for display: newest first, each section
  carrying the list of annotations geometrically nested inside it, and each
  annotation carrying its outgoing links.
  """
  def decorate_annotations(%Fresk{annotations: annotations}) do
    sorted = Enum.sort_by(annotations, & &1.inserted_at, {:desc, DateTime})

    Enum.map(sorted, fn annotation ->
      children =
        if annotation.type == "section" do
          section_coords = get_sorted_coordinates(annotation)

          Enum.filter(sorted, fn child ->
            child.id != annotation.id and
              is_within?(get_sorted_coordinates(child), section_coords)
          end)
        else
          []
        end

      %{
        id: annotation.id,
        type: annotation.type,
        title: annotation.title,
        description: annotation.description,
        x1: annotation.x1,
        y1: annotation.y1,
        x2: annotation.x2,
        y2: annotation.y2,
        children: children,
        links:
          Enum.map(annotation.links, fn link ->
            %{edge_id: link.id, kind: link.kind, target: link.target_annotation}
          end)
      }
    end)
  end

  @doc "Full overlay payload for the FreskCanvas JS hook (normalized coords)."
  def canvas_data(%Fresk{annotations: annotations} = fresk) do
    links =
      Enum.flat_map(annotations, fn a ->
        Enum.map(a.links, fn l ->
          %{
            id: l.id,
            source_id: l.source_annotation_id,
            target_id: l.target_annotation_id,
            line_style: l.line_style,
            color: l.color,
            kind: l.kind
          }
        end)
      end)

    %{
      annotations:
        Enum.map(annotations, fn a ->
          %{
            id: a.id,
            type: a.type,
            title: a.title,
            x1: a.x1,
            y1: a.y1,
            x2: a.x2,
            y2: a.y2,
            color: a.color,
            category: a.category,
            confidence: a.confidence,
            status: a.status
          }
        end),
      links: links,
      image: %{width: fresk.image_width, height: fresk.image_height}
    }
  end

  ## Geometry

  @doc "Returns sorted min/max coordinates from a pair of points forming a rectangle."
  def get_sorted_coordinates(%{x1: x1, y1: y1, x2: x2, y2: y2}) do
    %{xmin: min(x1, x2), ymin: min(y1, y2), xmax: max(x1, x2), ymax: max(y1, y2)}
  end

  @doc "Returns true if the child rectangle (first arg) sits within the parent rectangle (second arg)."
  def is_within?(
        %{xmin: c_xmin, ymin: c_ymin, xmax: c_xmax, ymax: c_ymax},
        %{xmin: p_xmin, ymin: p_ymin, xmax: p_xmax, ymax: p_ymax}
      ) do
    p_xmin <= c_xmin and p_ymin <= c_ymin and c_xmax <= p_xmax and c_ymax <= p_ymax
  end

  ## Export

  # The workbook has one sheet per entity — Fresks, Annotations, Arrows — and each
  # row is one stored record carrying every field it has (including primary and
  # foreign keys). So 100% of the labeled data, and the relationships between
  # records, can be reconstructed from the file. Coordinates are exported both as
  # the exact stored normalized floats (source of truth) and as convenience pixels.

  @fresk_columns ~w(fresk_id title date description status detection_error
                    image_width image_height inserted_at updated_at)

  @annotation_columns ~w(annotation_id fresk_id type title description
                         x1 y1 x2 y2 xmin_px ymin_px xmax_px ymax_px
                         image_width image_height color category source confidence
                         status containing_section_titles inserted_at updated_at)

  @arrow_columns ~w(link_id fresk_id source_annotation_id source_annotation_title
                    target_annotation_id target_annotation_title kind line_style
                    color origin confidence inserted_at updated_at)

  @doc """
  The full export as a list of `{sheet_name, [header_row | data_rows]}` tuples —
  one sheet per entity, every stored field a column, so the complete label set is
  reconstructable from the file.
  """
  def export_sheets do
    fresks = list_fresks()

    [
      {"Fresks", [@fresk_columns | Enum.map(fresks, &fresk_row/1)]},
      {"Annotations", [@annotation_columns | annotation_rows(fresks)]},
      {"Arrows", [@arrow_columns | arrow_rows(fresks)]}
    ]
  end

  # Kept for callers/tests that want the flattened annotation view.
  def export_header, do: @annotation_columns
  def export_rows, do: annotation_rows(list_fresks())

  defp fresk_row(f) do
    [
      f.id,
      f.title,
      f.dt,
      f.description,
      f.status,
      f.detection_error,
      f.image_width,
      f.image_height,
      ts(f.inserted_at),
      ts(f.updated_at)
    ]
  end

  defp annotation_rows(fresks) do
    Enum.flat_map(fresks, fn f ->
      w = f.image_width || 1
      h = f.image_height || 1
      sections = Enum.filter(f.annotations, &(&1.type == "section"))

      Enum.map(f.annotations, fn a ->
        coords = get_sorted_coordinates(a)

        containing_titles =
          sections
          |> Enum.reject(&(&1.id == a.id))
          |> Enum.filter(&is_within?(coords, get_sorted_coordinates(&1)))
          |> Enum.map_join(";;", &(&1.title || ""))

        [
          a.id,
          f.id,
          a.type,
          a.title,
          a.description,
          a.x1,
          a.y1,
          a.x2,
          a.y2,
          px(coords.xmin, w),
          px(coords.ymin, h),
          px(coords.xmax, w),
          px(coords.ymax, h),
          f.image_width,
          f.image_height,
          a.color,
          a.category,
          a.source,
          a.confidence,
          a.status,
          containing_titles,
          ts(a.inserted_at),
          ts(a.updated_at)
        ]
      end)
    end)
  end

  defp arrow_rows(fresks) do
    Enum.flat_map(fresks, fn f ->
      Enum.flat_map(f.annotations, fn a ->
        Enum.map(a.links, fn l ->
          [
            l.id,
            f.id,
            a.id,
            a.title,
            l.target_annotation.id,
            l.target_annotation.title,
            l.kind,
            l.line_style,
            l.color,
            l.origin,
            l.confidence,
            ts(l.inserted_at),
            ts(l.updated_at)
          ]
        end)
      end)
    end)
  end

  defp ts(nil), do: nil
  defp ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # Denormalize a 0..1 coordinate to an integer pixel against a dimension.
  defp px(nil, _dim), do: nil
  defp px(v, dim), do: round(v * dim)
end
