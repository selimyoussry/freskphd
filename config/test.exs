import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :freskphd, Freskphd.Repo,
  database: Path.expand("../freskphd_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# Stub the Mistral vision client with a Req.Test plug so tests never hit the
# network. Individual tests set the stub via `Req.Test.stub(Freskphd.VisionStub, ...)`.
config :freskphd, :vision, api_key: "test-key", plug: {Req.Test, Freskphd.VisionStub}

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :freskphd, FreskphdWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CJBmU0GCi3cOQBr/REFr/CSaix+LDGwUr8BTeLFaZUSiHwVctE/w1Qjx/OBVGdE7",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
