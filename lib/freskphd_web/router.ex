defmodule FreskphdWeb.Router do
  use FreskphdWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FreskphdWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FreskphdWeb do
    pipe_through :browser

    live "/", FreskHomeLive, :index
    live "/fresks/new", FreskHomeLive, :new
    live "/fresks/:id/edit", FreskHomeLive, :edit
    live "/fresks/:id", FreskShowLive, :show

    get "/fresks/:id/image/:kind", ImageController, :show
    get "/export.xlsx", ExportController, :export
  end

  # Other scopes may use custom stacks.
  # scope "/api", FreskphdWeb do
  #   pipe_through :api
  # end
end
