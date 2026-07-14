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
    test "header includes the new attribute columns" do
      header = Fresks.export_header()
      assert "link_line_style" in header
      assert "link_color" in header
      assert "annotation_color" in header
      assert "annotation_confidence" in header
    end

    test "rows denormalize coordinates to pixels" do
      fresk = fresk_fixture(%{"title" => "Ex"})

      cards = [
        %{
          "type" => "card",
          "title" => "A",
          "x1" => 0.5,
          "y1" => 0.25,
          "x2" => 0.6,
          "y2" => 0.5,
          "color" => "#abcdef",
          "confidence" => 0.9
        }
      ]

      {:ok, _} = Fresks.replace_detection(fresk, cards, [], [])

      header = Fresks.export_header()
      idx = fn col -> Enum.find_index(header, &(&1 == col)) end
      row = Enum.find(Fresks.export_rows(), &(Enum.at(&1, idx.("annotation_type")) == "card"))

      # 0.5 * 1000 = 500 ; 0.25 * 800 = 200
      assert Enum.at(row, idx.("annotation_xmin")) == 500
      assert Enum.at(row, idx.("annotation_ymin")) == 200
      assert Enum.at(row, idx.("annotation_color")) == "#abcdef"
    end
  end
end
