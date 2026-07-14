defmodule Freskphd.Fresks.Link do
  @moduledoc """
  A directed arrow from one annotation to another. The automated pass records the
  *visual* attributes — `line_style` (`"solid"` or `"dashed"`) and `color` (hex) —
  from which the semantic `kind` is derived downstream (it stays nullable here and
  the reviewer may override it). `origin` records provenance (`"auto"`/`"human"`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Freskphd.Fresks.Annotation

  schema "links" do
    field(:kind, :string)
    field(:line_style, :string)
    field(:color, :string)
    field(:origin, :string, default: "auto")
    field(:confidence, :float)

    belongs_to(:source_annotation, Annotation)
    belongs_to(:target_annotation, Annotation)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :kind,
      :line_style,
      :color,
      :origin,
      :confidence,
      :source_annotation_id,
      :target_annotation_id
    ])
    |> validate_required([:source_annotation_id, :target_annotation_id])
    |> validate_inclusion(:origin, ["auto", "human"])
    |> validate_inclusion(:line_style, ["solid", "dashed"], message: "must be solid or dashed")
  end
end
