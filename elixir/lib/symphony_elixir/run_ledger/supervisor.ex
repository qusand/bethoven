defmodule SymphonyElixir.RunLedger.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: SymphonyElixir.RunLedger.Registry},
      SymphonyElixir.RunLedger.WriterSupervisor
    ]

    # A writer registers its name through this Registry. Keeping both children
    # in one restart domain prevents a freshly restarted registry from leaving
    # live writers orphaned under the previous registry instance.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
