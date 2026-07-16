defmodule Freskphd.FresksTest do
  use Freskphd.DataCase, async: true

  alias Freskphd.Fresks

  defp fresk_fixture(attrs \\ %{}) do
    {:ok, fresk} =
      Fresks.create_fresk(
        Map.merge(
          %{"title" => "T", "dt" => "2026-01-01", "image_width" => 1000, "image_height" => 800},
          attrs
        )
      )

    fresk
  end

  describe "images in the DB" do
    test "create_fresk_with_image stores and serves the original bytes" do
      {:ok, fresk} =
        Fresks.create_fresk_with_image(%{"title" => "Fresk", "dt" => "2026-01-01"}, %{
          data: <<1, 2, 3, 4>>,
          content_type: "image/png"
        })

      img = Fresks.get_image(fresk.id, "original")
      assert img.data == <<1, 2, 3, 4>>
      assert img.byte_size == 4
      assert img.content_type == "image/png"
    end

    test "put_image upserts by (fresk, kind)" do
      fresk = fresk_fixture()
      {:ok, _} = Fresks.put_image(fresk, "display", %{content_type: "image/png", data: <<1>>})
      {:ok, _} = Fresks.put_image(fresk, "display", %{content_type: "image/png", data: <<2, 2>>})

      assert Fresks.get_image(fresk.id, "display").data == <<2, 2>>
    end
  end

  describe "geometry" do
    test "is_within? checks rectangle containment" do
      inner = Fresks.get_sorted_coordinates(%{x1: 0.2, y1: 0.2, x2: 0.3, y2: 0.3})
      outer = Fresks.get_sorted_coordinates(%{x1: 0.1, y1: 0.1, x2: 0.9, y2: 0.9})
      refute Fresks.is_within?(outer, inner)
      assert Fresks.is_within?(inner, outer)
    end
  end

  describe "replace_detection/4" do
    test "creates annotations and links from index-based specs" do
      fresk = fresk_fixture()

      cards = [
        %{
          "type" => "card",
          "title" => "Source",
          "x1" => 0.1,
          "y1" => 0.1,
          "x2" => 0.2,
          "y2" => 0.2
        },
        %{
          "type" => "card",
          "title" => "Target",
          "x1" => 0.5,
          "y1" => 0.5,
          "x2" => 0.6,
          "y2" => 0.6
        }
      ]

      sections = [
        %{
          "type" => "section",
          "title" => "Sec",
          "x1" => 0.0,
          "y1" => 0.0,
          "x2" => 1.0,
          "y2" => 1.0
        }
      ]

      links = [{0, 1, %{"line_style" => "dashed", "color" => "#ff0000"}}]

      {:ok, _annotations} = Fresks.replace_detection(fresk, cards, sections, links)

      fresk = Fresks.get_fresk!(fresk.id)
      assert length(fresk.annotations) == 3
      assert Enum.count(fresk.annotations, &(&1.type == "card")) == 2

      [link] = Enum.flat_map(fresk.annotations, & &1.links)
      assert link.line_style == "dashed"
      assert link.color == "#ff0000"
    end

    test "replaces any previous auto annotations" do
      fresk = fresk_fixture()
      card = %{"type" => "card", "x1" => 0.1, "y1" => 0.1, "x2" => 0.2, "y2" => 0.2}
      {:ok, _} = Fresks.replace_detection(fresk, [card, card], [], [])
      {:ok, _} = Fresks.replace_detection(fresk, [card], [], [])

      assert length(Fresks.get_fresk!(fresk.id).annotations) == 1
    end
  end

  describe "canvas_data/1" do
    test "returns annotations and links with normalized coords" do
      fresk = fresk_fixture()

      cards = [
        %{"type" => "card", "title" => "A", "x1" => 0.1, "y1" => 0.1, "x2" => 0.2, "y2" => 0.2}
      ]

      {:ok, _} = Fresks.replace_detection(fresk, cards, [], [])

      data = Fresks.canvas_data(Fresks.get_fresk!(fresk.id))
      assert data.image == %{width: 1000, height: 800}
      assert [%{title: "A", x1: 0.1}] = data.annotations
    end
  end

  describe "export" do
    # Fetch a sheet's {header, rows} by name, plus a column-index helper.
    defp sheet(name) do
      {^name, [header | rows]} = Enum.find(Fresks.export_sheets(), &(elem(&1, 0) == name))
      idx = fn col -> Enum.find_index(header, &(&1 == col)) end
      {header, rows, idx}
    end

    test "workbook has one sheet per entity" do
      names = Enum.map(Fresks.export_sheets(), &elem(&1, 0))
      assert names == ["Fresks", "Annotations", "Arrows"]
    end

    test "annotations sheet carries exact normalized coords, pixels, and status" do
      fresk = fresk_fixture(%{"title" => "Ex"})

      {:ok, a} =
        Fresks.create_annotation(%{
          "fresk_id" => fresk.id,
          "type" => "card",
          "title" => "A",
          "x1" => 0.5,
          "y1" => 0.25,
          "x2" => 0.6,
          "y2" => 0.5,
          "color" => "#abcdef",
          "category" => "orange",
          "source" => "human",
          "status" => "validated",
          "confidence" => 0.9
        })

      {_h, rows, idx} = sheet("Annotations")
      row = Enum.find(rows, &(Enum.at(&1, idx.("annotation_id")) == a.id))

      # exact normalized floats (source of truth) round-trip losslessly
      assert Enum.at(row, idx.("x1")) == 0.5
      assert Enum.at(row, idx.("y1")) == 0.25
      assert Enum.at(row, idx.("x2")) == 0.6
      assert Enum.at(row, idx.("y2")) == 0.5
      # convenience pixels: 0.5 * 1000 = 500 ; 0.25 * 800 = 200
      assert Enum.at(row, idx.("xmin_px")) == 500
      assert Enum.at(row, idx.("ymin_px")) == 200
      # every stored attribute is present
      assert Enum.at(row, idx.("fresk_id")) == fresk.id
      assert Enum.at(row, idx.("color")) == "#abcdef"
      assert Enum.at(row, idx.("category")) == "orange"
      assert Enum.at(row, idx.("source")) == "human"
      assert Enum.at(row, idx.("status")) == "validated"
      assert Enum.at(row, idx.("confidence")) == 0.9
    end

    test "arrows sheet carries the full link record (ids, endpoints, style, color, origin)" do
      fresk = fresk_fixture()

      {:ok, src} =
        Fresks.create_annotation(%{
          "fresk_id" => fresk.id,
          "type" => "card",
          "title" => "Src",
          "x1" => 0.1,
          "y1" => 0.1,
          "x2" => 0.2,
          "y2" => 0.2
        })

      {:ok, tgt} =
        Fresks.create_annotation(%{
          "fresk_id" => fresk.id,
          "type" => "section",
          "title" => "Tgt",
          "x1" => 0.5,
          "y1" => 0.5,
          "x2" => 0.6,
          "y2" => 0.6
        })

      {:ok, link} =
        Fresks.create_link(%{
          "source_annotation_id" => src.id,
          "target_annotation_id" => tgt.id,
          "origin" => "human",
          "line_style" => "dashed",
          "color" => "#dc2626"
        })

      {_h, rows, idx} = sheet("Arrows")
      row = Enum.find(rows, &(Enum.at(&1, idx.("link_id")) == link.id))

      assert Enum.at(row, idx.("fresk_id")) == fresk.id
      assert Enum.at(row, idx.("source_annotation_id")) == src.id
      assert Enum.at(row, idx.("source_annotation_title")) == "Src"
      assert Enum.at(row, idx.("target_annotation_id")) == tgt.id
      assert Enum.at(row, idx.("target_annotation_title")) == "Tgt"
      assert Enum.at(row, idx.("line_style")) == "dashed"
      assert Enum.at(row, idx.("color")) == "#dc2626"
      assert Enum.at(row, idx.("origin")) == "human"
    end

    test "a fresk with zero annotations still appears in the Fresks sheet" do
      fresk = fresk_fixture(%{"title" => "Empty", "status" => "review"})

      {_h, rows, idx} = sheet("Fresks")
      row = Enum.find(rows, &(Enum.at(&1, idx.("fresk_id")) == fresk.id))

      assert row, "empty fresk must not be dropped from the export"
      assert Enum.at(row, idx.("title")) == "Empty"
      assert Enum.at(row, idx.("status")) == "review"
      assert Enum.at(row, idx.("image_width")) == 1000
    end

    test "every annotation and link in the DB is represented (nothing dropped)" do
      fresk = fresk_fixture()

      {:ok, a} =
        Fresks.create_annotation(%{
          "fresk_id" => fresk.id,
          "type" => "card",
          "title" => "A",
          "x1" => 0.1,
          "y1" => 0.1,
          "x2" => 0.2,
          "y2" => 0.2
        })

      {:ok, b} =
        Fresks.create_annotation(%{
          "fresk_id" => fresk.id,
          "type" => "card",
          "title" => "B",
          "x1" => 0.3,
          "y1" => 0.3,
          "x2" => 0.4,
          "y2" => 0.4
        })

      {:ok, link} =
        Fresks.create_link(%{
          "source_annotation_id" => a.id,
          "target_annotation_id" => b.id,
          "origin" => "human"
        })

      {_h, ann_rows, ai} = sheet("Annotations")
      {_h, arrow_rows, li} = sheet("Arrows")

      ann_ids = Enum.map(ann_rows, &Enum.at(&1, ai.("annotation_id")))
      link_ids = Enum.map(arrow_rows, &Enum.at(&1, li.("link_id")))

      assert a.id in ann_ids
      assert b.id in ann_ids
      assert link.id in link_ids
    end
  end
end
