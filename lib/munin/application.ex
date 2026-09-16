defmodule Munin.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MuninWeb.Telemetry,
      Munin.Repo,
      {DNSCluster, query: Application.get_env(:munin, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Munin.PubSub},
      {Oban, Application.fetch_env!(:munin, Oban)},
      # Start a worker by calling: Munin.Worker.start_link(arg)
      # {Munin.Worker, arg},
      # Start to serve requests, typically the last entry
      MuninWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Munin.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MuninWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
