defmodule Staxx.DeploymentScope.EVMWorker do
  @moduledoc """
  EVM representation for Staxx system.

  All tasks that will iteract with EVM chain should go through this process.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Staxx.DeploymentScope.EVMWorkerRegistry
  alias Staxx.Proxy.ExChain
  alias Staxx.Proxy.NodeManager
  alias Staxx.DeploymentScope.EVMWorker.{State, ChainHelper}
  alias Staxx.DeploymentScope.EVMWorker.Storage.Record
  alias Staxx.ExChain.EVM.Notification

  @doc false
  def start_link({:existing, id}) when is_binary(id) do
    case NodeManager.node() do
      nil ->
        Logger.error("#{id}: No free ex_testchain node for starting EVM.")
        {:error, :no_free_node}

      node ->
        Logger.debug("#{id}: Node to start existing EVM selected: #{inspect(node)}")
        state = %State{id: id, start_type: :existing, node: node}
        GenServer.start_link(__MODULE__, {state, nil}, name: via_tuple(id))
    end
  end

  def start_link({:new, %{id: id, node: nil} = config}) when is_map(config) do
    case NodeManager.node() do
      nil ->
        Logger.error("#{id}: No free ex_testchain node for starting EVM.")
        {:error, :no_free_node}

      node ->
        config = Map.put(config, :node, node)
        start_link({:new, config})
    end
  end

  def start_link({:new, %{id: id} = config}) when is_map(config) do
    state = %State{
      id: id,
      start_type: :new,
      node: Map.get(config, :node),
      deploy_tag: Map.get(config, :deploy_tag),
      deploy_step_id: Map.get(config, :step_id, 0)
    }

    GenServer.start_link(__MODULE__, {state, config}, name: via_tuple(id))
  end

  @doc false
  def init({%State{id: id, node: node, start_type: :new} = state, config}) do
    Logger.debug("Starting new chain #{Map.get(config, :type)}")

    evm_config =
      config
      |> Map.put(:notify_pid, self())
      |> ExChain.to_config()

    {:ok, ^id} = ExChain.start(node, evm_config)

    Logger.debug("#{id}: Started new chain")

    # Collecting telemetry
    :telemetry.execute(
      [:staxx, :chain, :start],
      %{type: Map.get(config, :type)},
      %{
        id: id,
        node: node,
        accounts: Map.get(config, :accounts),
        deploy_tag: Map.get(config, :deploy_tag),
        step_id: Map.get(config, :step_id),
        clean_on_stop: Map.get(config, :clean_on_stop)
      }
    )

    # Store new chain process details
    state
    |> Record.from_state()
    |> Record.config(config)
    |> Record.store()

    # Enabling trap exit for process
    Process.flag(:trap_exit, true)

    {:ok, state}
  end

  @doc false
  def init({%State{id: id, node: node, start_type: :existing} = state, _}) when is_binary(id) do
    Logger.debug("#{id}: Loading chain details")
    {:ok, ^id} = ExChain.start_existing(node, id, self())
    Logger.debug("#{id}: Started existing chain")

    Logger.debug("#{id}: existing state merged to: #{inspect(state)}")

    # Store updated chain state
    state
    |> Record.from_state()
    |> Record.store()

    # Enabling trap exit for process
    Process.flag(:trap_exit, true)

    {:ok, state}
  end

  @doc false
  def terminate(_, %State{id: id, node: node}) do
    Logger.debug(fn -> "Got stop signal... Terminating" end)
    # Sending termination signal
    ExChain.stop(node, id)

    # Collecting telemetry
    :telemetry.execute(
      [:staxx, :chain, :stop],
      %{},
      %{
        id: id,
        node: node
      }
    )

    case ChainHelper.wait_for_event(id, :stopped) do
      :timeout ->
        Logger.error(fn -> "Timed out waiting chain to terminate..." end)

      _ ->
        Logger.debug(fn -> "Chain #{id} stopped." end)
    end
  end

  @doc false
  def handle_continue(:deployment_failed, state) do
    new_state =
      state
      |> State.notify(:deployment_failed, "Deployment process failed.")
      |> State.notify(:failed)
      |> State.status(:failed)
      |> State.store()

    {:noreply, new_state}
  end

  @doc false
  def handle_info({:EXIT, from, reason}, %State{deploy_pid: pid} = state) do
    case pid == from do
      true ->
        Logger.debug(fn ->
          "Deployment worker process terminated: #{inspect(reason)}"
        end)

        {:noreply, state}

      false ->
        Logger.debug(fn ->
          """
          Exit trapped for chain process
            From PID: #{inspect(from)}
            Exit reason: #{inspect(reason)}
            Chain state:
              #{inspect(state, pretty: true)}
          """
        end)

        {:stop, reason, state}
    end
  end

  @doc false
  def handle_info(
        %Notification{event: :status_changed, data: :terminated},
        %State{id: id} = state
      ) do
    Logger.debug("#{id}: EVM stopped, going down")

    new_state =
      state
      |> State.status(:terminated)
      |> State.chain_status(:terminated)
      |> State.notify(:terminated)
      |> State.store()

    {:stop, :normal, new_state}
  end

  @doc false
  def handle_info(
        %Notification{event: :status_changed, data: status},
        %State{id: id} = state
      ) do
    Logger.debug("#{id}: EVM status changed to #{status}")

    updated_state =
      state
      |> ChainHelper.handle_status_change(status)

    {:noreply, %State{updated_state | chain_status: status}}
  end

  @doc false
  def handle_info(
        %Notification{event: :started, data: details},
        state
      ) do
    new_state = ChainHelper.handle_evm_started(state, details)

    case new_state do
      %State{status: :initializing} ->
        # If deployment process started we have to set timeout
        {:noreply, new_state, Application.get_env(:deployment_scope, :deployment_timeout)}

      _ ->
        {:noreply, new_state}
    end
  end

  @doc false
  def handle_info(%Notification{event: event, data: data}, %State{id: id} = state) do
    Logger.debug("#{id}: Received notification for chain with event: #{inspect(event)}")
    State.notify(state, event, data)
    {:noreply, state}
  end

  @doc false
  def handle_info(:timeout, %State{id: id, status: :initializing} = state) do
    Logger.error("#{id}: Waiting deployment failed: timeout")

    {:noreply, state, {:continue, :deployment_failed}}
  end

  @doc false
  def handle_info(msg, %State{id: id} = state) do
    Logger.debug("#{id}: Handled message #{inspect(msg)}")
    {:noreply, state}
  end

  @doc false
  def handle_call(:node, _from, %State{node: node} = state),
    do: {:reply, node, state}

  def handle_call({:take_snapshot, description}, _from, %State{id: id, node: node} = state) do
    resp = ExChain.take_snapshot(node, id, description)
    {:reply, resp, state}
  end

  def handle_call({:revert_snapshot, snapshot_id}, _from, %State{id: id, node: node} = state) do
    with {:load, snapshot} when is_map(snapshot) <-
           {:load, ExChain.load_snapshot(node, snapshot_id)},
         :ok <- ExChain.revert_snapshot(node, id, snapshot) do
      Logger.debug("#{id}: Reverting snapshot #{snapshot_id}")
      {:reply, :ok, state}
    else
      {:load, err} ->
        Logger.error("Failed to load snapshot details #{inspect(err)}")
        {:reply, {:error, "failed to load snapshot details #{snapshot_id}"}, state}

      _ ->
        Logger.error("#{id}: failed to revert snapshot #{snapshot_id}")
        {:reply, {:error, "something wrong on reverting snapshot #{snapshot_id}"}, state}
    end
  end

  @doc false
  def handle_cast(:stop, %State{id: id, node: node} = state) do
    Logger.debug("#{id} Terminating chain")
    ExChain.stop(node, id)
    {:noreply, state}
  end

  @doc false
  def handle_cast({:deployment_finished, request_id, data}, state) do
    new_state = ChainHelper.handle_deployment_finished(state, request_id, data)

    # Collecting telemetry
    :telemetry.execute(
      [:staxx, :chain, :deployment, :success],
      %{request_id: request_id},
      %{
        id: Map.get(state, :id),
        step_id: Map.get(state, :deploy_step_id)
      }
    )

    {:noreply, new_state}
  end

  @doc false
  def handle_cast(
        {:deployment_failed, request_id, msg},
        %State{id: id, status: :initializing} = state
      ) do
    Logger.error("""
    #{id}: Handling deployment failure #{request_id}:
      #{inspect(msg, printable_limit: :infinity, limit: :infinity, pretty: true)}
    """)

    # Collecting telemetry
    :telemetry.execute(
      [:staxx, :chain, :deployment, :failed],
      %{request_id: request_id},
      %{
        id: Map.get(state, :id),
        step_id: Map.get(state, :deploy_step_id)
      }
    )

    {:noreply, state, {:continue, :deployment_failed}}
  end

  @doc """
  Generates via cause for GenServer registration
  """
  @spec via_tuple(binary) :: {:via, Registry, {EVMWorkerRegistry, binary}}
  def via_tuple(id),
    do: {:via, Registry, {EVMWorkerRegistry, id}}

  @doc """
  Handle deployment by chain process
  """
  @spec handle_deployment(binary, binary, term()) :: term()
  def handle_deployment(id, request_id, data),
    do: GenServer.cast(via_tuple(id), {:deployment_finished, request_id, data})

  @doc """
  Send deployment failure event to chain process
  """
  @spec handle_deployment_failure(binary, binary, map()) :: term()
  def handle_deployment_failure(id, request_id, %{"msg" => msg, "stderrB64" => err}) do
    decoded_err = Base.decode64!(err)
    Logger.error("#{id}: Deployment failed\n #{decoded_err}")

    GenServer.cast(via_tuple(id), {:deployment_failed, request_id, msg})
  end
end
