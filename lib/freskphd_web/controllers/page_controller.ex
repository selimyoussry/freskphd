defmodule FreskphdWeb.PageController do
  use FreskphdWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
