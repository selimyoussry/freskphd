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

  @export_header [
    "fresk_id",
    "fresk_title",
    "fresk_date",
    "fresk_description",
    "annotation_id",
    "annotation_type",
    "annotation_title",
    "annotation_description",
    # Pixel coordinates in the original image (denormalized from stored 0..1).
    "annotation_xmin",
    "annotation_ymin",
    "annotation_xmax",
    "annotation_ymax",
    "annotation_image_width",
    "annotation_image_height",
    "annotation_color",
    "annotation_category",
    "annotation_confidence",
    "annotation_source",
    "section_titles",
    "link_kind",
    "link_line_style",
    "link_color",
    "link_source_annotation_id",
    "link_source_annotation_title",
    "link_target_annotation_id",
    "link_target_annotation_title"
  ]

  def export_header, do: @export_header

  @doc "Flattens every fresk/annotation/link into rows matching `export_header/0`."
  def export_rows do
    Enum.flat_map(list_fresks(), fn fresk ->
      w = fresk.image_width || 1
      h = fresk.image_height || 1

      base = %{
        "fresk_id" => fresk.id,
        "fresk_title" => fresk.title,
        "fresk_date" => fresk.dt,
        "fresk_description" => fresk.description
      }

      Enum.flat_map(fresk.annotations, fn ann ->
        coords = get_sorted_coordinates(ann)

        section_titles =
          fresk.annotations
          |> Enum.filter(&(&1.type == "section" and &1.id != ann.id))
          |> Enum.flat_map(fn section ->
            if is_within?(coords, get_sorted_coordinates(section)),
              do: [section.title],
              else: []
          end)

        annotation_row =
          Map.merge(base, %{
            "annotation_id" => ann.id,
            "annotation_type" => ann.type,
            "annotation_title" => ann.title,
            "annotation_description" => ann.description,
            "annotation_xmin" => px(coords.xmin, w),
            "annotation_ymin" => px(coords.ymin, h),
            "annotation_xmax" => px(coords.xmax, w),
            "annotation_ymax" => px(coords.ymax, h),
            "annotation_image_width" => w,
            "annotation_image_height" => h,
            "annotation_color" => ann.color,
            "annotation_category" => ann.category,
            "annotation_confidence" => ann.confidence,
            "annotation_source" => ann.source,
            "section_titles" => Enum.join(section_titles, ";;")
          })

        link_rows =
          Enum.map(ann.links, fn link ->
            Map.merge(base, %{
              "link_kind" => link.kind,
              "link_line_style" => link.line_style,
              "link_color" => link.color,
              "link_source_annotation_id" => ann.id,
              "link_source_annotation_title" => ann.title,
              "link_target_annotation_id" => link.target_annotation.id,
              "link_target_annotation_title" => link.target_annotation.title
            })
          end)

        [annotation_row | link_rows]
      end)
    end)
    |> Enum.map(fn row -> Enum.map(@export_header, &Map.get(row, &1)) end)
  end

  # Denormalize a 0..1 coordinate to an integer pixel against a dimension.
  defp px(nil, _dim), do: nil
  defp px(v, dim), do: round(v * dim)
end
