defmodule FreskphdWeb.FreskLiveTest do
  use FreskphdWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Freskphd.Fresks

  defp fresk_fixture(status \\ "review") do
    {:ok, fresk} =
      Fresks.create_fresk(%{
        "title" => "Climate Fresk",
        "dt" => "2026-01-01",
        "image_width" => 1000,
        "image_height" => 800,
        "status" => status
      })

    fresk
  end

  defp card(fresk, title, box) do
    {x1, y1, x2, y2} = box

    {:ok, ann} =
      Fresks.create_annotation(%{
        "fresk_id" => fresk.id,
        "type" => "card",
        "title" => title,
        "x1" => x1,
        "y1" => y1,
        "x2" => x2,
        "y2" => y2
      })

    ann
  end

  describe "home gallery" do
    test "renders an empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "No fresk yet"
    end

    test "lists a fresk with card/arrow counts", %{conn: conn} do
      fresk = fresk_fixture()
      card(fresk, "A", {0.1, 0.1, 0.2, 0.2})

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Climate Fresk"
      assert html =~ "1 cards"
    end

    test "deletes a fresk", %{conn: conn} do
      fresk = fresk_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      assert render(view) =~ "Climate Fresk"
      render_click(view, "delete", %{"id" => to_string(fresk.id)})
      refute render(view) =~ "Climate Fresk"
    end
  end

  describe "review workspace" do
    test "pushes the canvas overlay data on mount", %{conn: conn} do
      fresk = fresk_fixture()
      card(fresk, "CO2", {0.1, 0.1, 0.2, 0.2})

      {:ok, view, _html} = live(conn, ~p"/fresks/#{fresk.id}")

      assert_push_event(view, "canvas:set", %{
        annotations: [%{title: "CO2"}],
        image: %{width: 1000}
      })

      assert render(view) =~ "CO2"
    end

    test "selecting an annotation shows the inspector", %{conn: conn} do
      fresk = fresk_fixture()
      ann = card(fresk, "Methane", {0.1, 0.1, 0.2, 0.2})

      {:ok, view, _html} = live(conn, ~p"/fresks/#{fresk.id}")
      render_hook(view, "select-annotation", %{"id" => ann.id})

      html = render(view)
      assert html =~ "Selected card"
    end

    test "drawing a box creates an annotation", %{conn: conn} do
      fresk = fresk_fixture()
      {:ok, view, _html} = live(conn, ~p"/fresks/#{fresk.id}")

      render_hook(view, "annotation:create", %{
        "type" => "card",
        "x1" => 0.3,
        "y1" => 0.3,
        "x2" => 0.4,
        "y2" => 0.4
      })

      [ann] = Fresks.get_fresk!(fresk.id).annotations
      assert ann.type == "card"
      assert ann.source == "human"
    end

    test "moving an annotation updates its coordinates", %{conn: conn} do
      fresk = fresk_fixture()
      ann = card(fresk, "A", {0.1, 0.1, 0.2, 0.2})

      {:ok, view, _html} = live(conn, ~p"/fresks/#{fresk.id}")

      render_hook(view, "annotation:move", %{
        "id" => ann.id,
        "x1" => 0.5,
        "y1" => 0.5,
        "x2" => 0.6,
        "y2" => 0.6
      })

      assert Fresks.get_annotation!(ann.id).x1 == 0.5
    end

    test "linking two annotations creates an arrow", %{conn: conn} do
      fresk = fresk_fixture()
      src = card(fresk, "Src", {0.1, 0.1, 0.2, 0.2})
      tgt = card(fresk, "Tgt", {0.5, 0.5, 0.6, 0.6})

      {:ok, view, _html} = live(conn, ~p"/fresks/#{fresk.id}")
      render_hook(view, "link:create", %{"source_id" => src.id, "target_id" => tgt.id})

      links = Fresks.get_fresk!(fresk.id).annotations |> Enum.flat_map(& &1.links)
      assert [%{source_annotation_id: sid, target_annotation_id: tid}] = links
      assert sid == src.id and tid == tgt.id
    end

    test "deleting removes the annotation", %{conn: conn} do
      fresk = fresk_fixture()
      ann = card(fresk, "A", {0.1, 0.1, 0.2, 0.2})

      {:ok, view, _html} = live(conn, ~p"/fresks/#{fresk.id}")
      render_hook(view, "annotation:delete", %{"id" => ann.id})

      assert Fresks.get_fresk!(fresk.id).annotations == []
    end

    test "validating sets the fresk status", %{conn: conn} do
      fresk = fresk_fixture()
      {:ok, view, _html} = live(conn, ~p"/fresks/#{fresk.id}")

      render_click(view, "validate-fresk")
      assert Fresks.get_fresk!(fresk.id).status == "validated"
    end
  end

  describe "xlsx export" do
    test "downloads a spreadsheet", %{conn: conn} do
      fresk = fresk_fixture()
      card(fresk, "A", {0.1, 0.1, 0.2, 0.2})

      conn = get(conn, ~p"/export.xlsx")
      assert get_resp_header(conn, "content-type") |> hd() =~ "spreadsheetml"
      assert <<0x50, 0x4B, _::binary>> = conn.resp_body
    end
  end
end
