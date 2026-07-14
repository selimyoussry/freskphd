defmodule Freskphd.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FreskphdWeb.Telemetry,
      Freskphd.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:freskphd, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:freskphd, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Freskphd.PubSub},
      # Runs fresk detection jobs in the background.
      {Task.Supervisor, name: Freskphd.TaskSupervisor},
      # Start to serve requests, typically the last entry
      FreskphdWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Freskphd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FreskphdWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
