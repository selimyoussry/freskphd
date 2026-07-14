defmodule FreskphdWeb.ImageController do
  @moduledoc """
  Serves fresk image bytes stored in the DB (`fresk_images`). The `:kind` path
  segment is `"original"` or `"display"`.
  """
  use FreskphdWeb, :controller

  alias Freskphd.Fresks

  def show(conn, %{"id" => id, "kind" => kind}) when kind in ["original", "display"] do
    case Fresks.get_image(id, kind) do
      nil ->
        conn |> put_status(:not_found) |> text("not found")

      image ->
        conn
        |> put_resp_content_type(image.content_type)
        |> put_resp_header("cache-control", "private, max-age=31536000")
        |> send_resp(200, image.data)
    end
  end

  def show(conn, _params), do: conn |> put_status(:not_found) |> text("not found")
end
