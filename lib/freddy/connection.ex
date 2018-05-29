defmodule Freddy.Connection do
  @moduledoc """
  Stable AMQP connection.
  """

  @type connection :: GenServer.server()

  # Hard coded for now, can make configurable later
  @reconnect_interval 1000

  use Connection

  @doc """
  Start a new AMQP connection. See `AMQP.Connection.open/1` for supported
  connection options.
  """
  @spec start_link(Keyword.t(), GenServer.options()) :: GenServer.on_start()
  def start_link(connection_opts \\ [], gen_server_opts \\ []) do
    Connection.start_link(__MODULE__, connection_opts, gen_server_opts)
  end

  @doc """
  Closes an AMQP connection. This will cause process to reconnect.
  """
  @spec close(connection) :: :ok | {:error, reason :: term}
  def close(connection) do
    Connection.call(connection, :close)
  end

  @doc """
  Stops the connection process
  """
  def stop(connection) do
    GenServer.stop(connection)
  end

  @doc """
  Opens a new AMQP channel
  """
  @spec open_channel(connection) :: {:ok, AMQP.Channel.t()} | {:error, reason :: term}
  def open_channel(connection) do
    Connection.call(connection, :open_channel)
  end

  @doc """
  Returns underlying AMQP connection structure
  """
  @spec get_connection(connection) :: {:ok, AMQP.Connection.t()} | {:error, :closed}
  def get_connection(connection) do
    Connection.call(connection, :get)
  end

  @doc false
  @spec child_spec(term) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  # Connection callbacks

  import Record

  defrecordp :state,
    opts: nil,
    connection: nil,
    channels: %{}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:connect, :init, state(opts: opts)}
  end

  @impl true
  def connect(_info, state(opts: opts) = state) do
    case AMQP.Connection.open(opts) do
      {:ok, connection} ->
        Process.link(connection.pid)
        {:ok, state(state, connection: connection)}

      _error ->
        {:backoff, @reconnect_interval, state}
    end
  end

  @impl true
  def disconnect(info, state(connection: connection) = state) do
    case info do
      {:close, from} ->
        result =
          try do
            AMQP.Connection.close(connection)
          catch
            :exit, {:noproc, _} -> :closed
          end

        Connection.reply(from, result)

      _other ->
        :ok
    end

    {:connect, :reconnect, state(state, connection: nil)}
  end

  @impl true
  def handle_call(_, _, state(connection: nil) = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call(:get, _from, state(connection: connection) = state) do
    {:reply, {:ok, connection}, state}
  end

  def handle_call(
        :open_channel,
        {from, _ref},
        state(connection: connection, channels: channels) = state
      ) do
    try do
      case AMQP.Channel.open(connection) do
        {:ok, chan} ->
          monitor_ref = Process.monitor(from)
          channels = Map.put(channels, monitor_ref, chan)
          {:reply, {:ok, chan}, state(state, channels: channels)}

        # amqp 1.0 format
        {:error, _reason} = reply ->
          {:reply, reply, state}

        # amqp 0.x format
        reason ->
          {:reply, {:error, reason}, state}
      end
    catch
      :exit, {:noproc, _} ->
        {:reply, {:error, :closed}, state}

      _, _ ->
        {:reply, {:error, :closed}, state}
    end
  end

  def handle_call(:close, from, state) do
    {:disconnect, {:close, from}, state}
  end

  @impl true
  def handle_info(
        {:EXIT, connection, {:shutdown, {:server_initiated_close, _, _}}},
        state(connection: %{pid: connection}) = state
      ) do
    {:disconnect, {:error, :server_initiated_close}, state}
  end

  def handle_info({:EXIT, connection, reason}, state(connection: %{pid: connection}) = state) do
    {:disconnect, {:error, reason}, state}
  end

  def handle_info(
        {:EXIT, connection, {:shutdown, :normal}},
        state(connection: %{pid: connection}) = state
      ) do
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state(channels: channels) = state) do
    state =
      case Map.get(channels, monitor_ref) do
        nil ->
          state

        chan ->
          try do
            :ok = AMQP.Channel.close(chan)
          catch
            _, _ -> :ok
          end

          state(state, channels: Map.delete(channels, monitor_ref))
      end

    {:noreply, state}
  end

  def handle_info(_info, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state(connection: connection)) do
    if connection do
      AMQP.Connection.close(connection)
    end
  end
end
