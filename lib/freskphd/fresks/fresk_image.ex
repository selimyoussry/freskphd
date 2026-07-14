defmodule Freskphd.Fresks.FreskImage do
  @moduledoc """
  Raw image bytes for a fresk, stored in the DB. Each fresk has an `"original"`
  (the uploaded PNG) and a `"display"` (a downscaled preview served to the
  browser and fed to the VLM). Served by `FreskphdWeb.ImageController`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Freskphd.Fresks.Fresk

  @kinds ["original", "display"]

  schema "fresk_images" do
    field(:kind, :string)
    field(:content_type, :string)
    field(:width, :integer)
    field(:height, :integer)
    field(:byte_size, :integer)
    field(:data, :binary)

    belongs_to(:fresk, Fresk)

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc false
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:kind, :content_type, :width, :height, :byte_size, :data, :fresk_id])
    |> validate_required([:kind, :content_type, :data, :fresk_id])
    |> validate_inclusion(:kind, @kinds)
  end
end
