defmodule Freskphd.Fresks.Annotation do
  @moduledoc """
  A rectangular annotation on a fresk, `"card"` or `"section"`. Coordinates
  (`x1,y1,x2,y2`) are normalized to 0..1 against the original image, so they are
  resolution independent. A section geometrically contains the cards whose
  rectangle sits within its own (see `Freskphd.Fresks.is_within?/2`).

  `source` records provenance (`"auto"` from detection, `"human"` from the
  reviewer); `status` is `"pending"` until validated. Arrows between annotations
  are stored separately as `Freskphd.Fresks.Link`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Freskphd.Fresks.{Fresk, Link}

  schema "annotations" do
    field(:type, :string)
    field(:title, :string)
    field(:description, :string)
    field(:x1, :float)
    field(:y1, :float)
    field(:x2, :float)
    field(:y2, :float)
    field(:fresk_width, :float)
    field(:color, :string)
    field(:category, :string)
    field(:source, :string, default: "auto")
    field(:confidence, :float)
    field(:status, :string, default: "pending")

    belongs_to(:fresk, Fresk)
    has_many(:links, Link, foreign_key: :source_annotation_id)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, [
      :type,
      :title,
      :description,
      :x1,
      :y1,
      :x2,
      :y2,
      :fresk_width,
      :color,
      :category,
      :source,
      :confidence,
      :status,
      :fresk_id
    ])
    |> validate_required([:type, :x1, :y1, :x2, :y2, :fresk_id])
    |> validate_inclusion(:type, ["card", "section"])
    |> validate_inclusion(:source, ["auto", "human"])
    |> validate_inclusion(:status, ["pending", "validated"])
  end
end
