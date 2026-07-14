# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :freskphd,
  ecto_repos: [Freskphd.Repo],
  generators: [timestamp_type: :utc_datetime]

# The Mistral vision client (base_url/api_key come from the environment in
# config/runtime.exs). Cost is a non-issue here, so we default to the strongest
# vision model.
config :freskphd, :vision,
  model: "mistral-large-2512",
  receive_timeout: 180_000,
  # Mistral allows at most 8 images per request.
  max_crops_per_call: 8

# The pyvision OpenCV sidecar (a standalone uv project) invoked by
# Freskphd.Detection via `uv run`.
config :freskphd, :detection,
  uv_bin: "uv",
  pyvision_dir: Path.expand("../pyvision", __DIR__),
  display_max_dim: 2560,
  detect_max_dim: 2400

# Configure the endpoint
config :freskphd, FreskphdWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FreskphdWeb.ErrorHTML, json: FreskphdWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Freskphd.PubSub,
  live_view: [signing_salt: "BmCHsroG"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  freskphd: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  freskphd: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
