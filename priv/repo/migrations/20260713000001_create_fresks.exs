defmodule Freskphd.Repo.Migrations.CreateFresks do
  use Ecto.Migration

  def change do
    create table(:fresks) do
      add(:title, :string, null: false)
      add(:description, :string)
      add(:dt, :string, null: false)
      add(:image_width, :integer)
      add(:image_height, :integer)
      # pending -> processing -> review -> validated (or failed)
      add(:status, :string, null: false, default: "pending")
      add(:detection_error, :string)

      timestamps(type: :utc_datetime)
    end

    # Image bytes live in the DB (original + downscaled display preview) so the
    # whole app is a single self-contained SQLite file. Kept in their own table
    # to keep the fresks list queries light.
    create table(:fresk_images) do
      add(:fresk_id, references(:fresks, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:content_type, :string, null: false)
      add(:width, :integer)
      add(:height, :integer)
      add(:byte_size, :integer)
      add(:data, :binary, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:fresk_images, [:fresk_id, :kind]))

    create table(:annotations) do
      add(:type, :string, null: false)
      add(:title, :string)
      add(:description, :string)
      # Coordinates are normalized to 0..1 against the original image.
      add(:x1, :float)
      add(:y1, :float)
      add(:x2, :float)
      add(:y2, :float)
      add(:fresk_width, :float)
      add(:color, :string)
      add(:category, :string)
      add(:source, :string, null: false, default: "auto")
      add(:confidence, :float)
      add(:status, :string, null: false, default: "pending")
      add(:fresk_id, references(:fresks, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:annotations, [:fresk_id]))

    create table(:links) do
      # kind is now derived downstream from (line_style, color); nullable.
      add(:kind, :string)
      add(:line_style, :string)
      add(:color, :string)
      add(:origin, :string, null: false, default: "auto")
      add(:confidence, :float)
      add(:source_annotation_id, references(:annotations, on_delete: :delete_all), null: false)
      add(:target_annotation_id, references(:annotations, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:links, [:source_annotation_id]))
    create(index(:links, [:target_annotation_id]))
  end
end
