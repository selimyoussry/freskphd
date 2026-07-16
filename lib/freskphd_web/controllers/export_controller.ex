defmodule FreskphdWeb.ExportController do
  use FreskphdWeb, :controller

  alias Elixlsx.{Sheet, Workbook}
  alias Freskphd.Fresks

  def export(conn, _params) do
    sheets =
      Enum.map(Fresks.export_sheets(), fn {name, rows} -> %Sheet{name: name, rows: rows} end)

    workbook = %Workbook{sheets: sheets}
    filename = "#{Date.utc_today() |> Date.to_iso8601()}-fresks-export.xlsx"

    {:ok, {_charlist_name, binary}} = Elixlsx.write_to_memory(workbook, filename)

    conn
    |> put_resp_content_type("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    |> send_download({:binary, binary}, filename: filename)
  end
end
