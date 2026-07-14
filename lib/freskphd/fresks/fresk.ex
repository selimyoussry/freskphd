defmodule Freskphd.Fresks.Fresk do
  @moduledoc """
  A fresk is an uploaded Mural export (image bytes stored in `fresk_images`).
  An automated first pass (OpenCV + Mistral VLM) fills in `annotations` (cards and
  sections) and the arrows linking them, which a human then validates/corrects.

  `status` tracks that flow: `pending` (uploaded) -> `processing` (detection
  running) -> `review` (detected, awaiting human) -> `validated`; or `failed`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Freskphd.Fresks.{Annotation, FreskImage}

  @statuses ["pending", "processing", "review", "validated", "failed"]

  schema "fresks" do
    field(:title, :string)
    field(:description, :string)
    field(:dt, :string)
    field(:image_width, :integer)
    field(:image_height, :integer)
    field(:status, :string, default: "pending")
    field(:detection_error, :string)

    has_many(:annotations, Annotation)
    has_many(:images, FreskImage)

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(fresk, attrs) do
    fresk
    |> cast(attrs, [
      :title,
      :description,
      :dt,
      :image_width,
      :image_height,
      :status,
      :detection_error
    ])
    |> validate_required([:title, :dt])
    |> validate_inclusion(:status, @statuses)
  end
end
