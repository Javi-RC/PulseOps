defmodule PulseOps.Release do
  @moduledoc """
  Tasks that have to run in a release, where Mix is not available.

  `mix ecto.migrate` does not exist in a built release — Mix is a build tool and
  is deliberately left out of the runtime — so migrations need an entry point
  that starts just the repository, does the work, and stops it again. This is
  that entry point, and `bin/pulse_ops eval "PulseOps.Release.migrate()"` is how
  a deployment calls it.
  """

  @app :pulse_ops

  @doc """
  Runs every pending migration.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _fun_return, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls a repository back to a given version.
  """
  def rollback(repo, version) do
    load_app()

    {:ok, _fun_return, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # Loads the application without starting it, so the repository can be started
  # on its own. Starting the whole application here would start the monitors and
  # begin probing services before the migration that the probes may depend on
  # has run.
  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
