alias Experimental.{GenStage}
defmodule RPCMessageHandler do
  use GenStage
  require Logger
  @transport Application.get_env(:json_rpc, :transport)
  @update_server Application.get_env(:fb, :update_server)
  @doc """
    This is where all JSON RPC messages come in.
    Currently only from Mqtt, but is technically transport agnostic.
    Right now we set @transport to MqttHandler, but it could technically be
    In config and set to anything that can emit and recieve JSON RPC messages.
  """

  def start_link() do
    GenStage.start_link(__MODULE__, :ok)
  end

  def init(_args) do
    {:consumer, :ok, subscribe_to: [RPCMessageManager]}
  end

  def handle_events(events, _from, state) do
    for event <- events do
      handle_rpc(event)
    end
    {:noreply, [], state}
  end

  # JSON RPC RESPONSE
  def ack_msg(id) when is_bitstring(id) do
    Poison.encode!(
    %{id: id,
      error: nil,
      result: %{"OK" => "OK"} })
  end

  # JSON RPC RESPONSE ERROR
  def ack_msg(id, {name, message}) when is_bitstring(id) and is_bitstring(name) and is_bitstring(message) do
    Logger.error("RPC ERROR")
    IO.inspect({name, message})
    Poison.encode!(
    %{id: id,
      error: %{name: name,
               message: message },
      result: nil})
  end

  @doc """
    Logs a message to the frontend.
  """
  def log_msg(message, channels, tags)
  when is_list(channels)
       and is_list(tags)
       and is_bitstring(message) do
    Poison.encode!(
      %{ id: nil,
         method: "log_message",
         params: [%{ status: BotState.get_status,
                     time: :os.system_time(:seconds),
                     message: message,
                     channels: channels,
                     tags: tags }] })
  end

  def handle_rpc(%{"method" => method, "params" => params, "id" => id})
  when is_list(params) and
       is_bitstring(method) and
       is_bitstring(id)
  do
    case do_handle(method, params) do
      :ok -> @transport.emit(ack_msg(id))
      {:error, name, message} -> @transport.emit(ack_msg(id, {name, message}))
      unknown_error -> @transport.emit(ack_msg(id, {"unknown_error", "#{inspect unknown_error}"}))
    end
  end

  def handle_rpc(broken_rpc) do
    Logger.debug("Got a broken RPC message!!")
    IO.inspect broken_rpc
  end

  def do_handle("toggle_os_auto_update", []) do
    BotState.toggle_os_auto_update
  end

  def do_handle("toggle_fw_auto_update", []) do
    BotState.toggle_fw_auto_update
  end

  # E STOP
  def do_handle("emergency_stop", _) do
    GenServer.call UartHandler, :e_stop
    GenServer.call SequenceManager, :e_stop
    :ok
  end

  # Home All
  def do_handle("home_all", [ %{"speed" => s} ]) when is_integer s do
    spawn fn -> Command.home_all(s) end
    :ok
  end

  def do_handle("home_all", params) do
    Logger.debug("bad params for home_all")
    IO.inspect(params)
    {:error, "BAD_PARAMS",
      Poison.encode!(%{"speed" => "number"})}
  end

  # WRITE_PIN
  def do_handle("write_pin", [ %{"pin_mode" => 1, "pin_number" => p, "pin_value" => v} ])
    when is_integer p and
         is_integer v
  do
    spawn fn -> Command.write_pin(p,v,1) end
    :ok
  end

  def do_handle("write_pin", [ %{"pin_mode" => 0, "pin_number" => p, "pin_value" => v} ])
    when is_integer p and
         is_integer v
  do
    spawn fn -> Command.write_pin(p,v,0) end
    :ok
  end

  def do_handle("write_pin", _) do
    {:error, "BAD_PARAMS",
      Poison.encode!(%{"pin_mode" => "1 or 2", "pin_number" => "number", "pin_value" => "number"})}
  end

  def do_handle("toggle_pin", [%{"pin_number" => p}]) when is_integer(p) do
    spawn fn -> Command.toggle_pin(p) end
    :ok
  end

  def do_handle("toggle_pin", params) do
    Logger.error ("#{inspect params}")
    {:error, "BAD_PARAMS",
      Poison.encode!(%{"pin_number" => "number"})}
  end

  # Move to a specific coord
  def do_handle("move_absolute",  [%{"speed" => s, "x" => x, "y" => y, "z" => z}])
  when is_integer(x) and
       is_integer(y) and
       is_integer(z) and
       is_integer(s)
  do
    spawn fn -> Command.move_absolute(x,y,z,s) end
    :ok
  end

  def do_handle("move_absolute",  params) do
    Logger.debug("bad params for Move Absolute")
    IO.inspect params
    {:error, "BAD_PARAMS",
      Poison.encode!(%{"x" => "number", "y" => "number", "z" => "number", "speed" => "number"})}
  end

  # Move relative to current x position
  def do_handle("move_relative", [%{"speed" => speed,
                                    "x" => x_move_by,
                                    "y" => y_move_by,
                                    "z" => z_move_by}])
    when is_integer(speed) and
         is_integer(x_move_by) and
         is_integer(y_move_by) and
         is_integer(z_move_by)
  do
    spawn fn -> Command.move_relative(%{x: x_move_by, y: y_move_by, z: z_move_by, speed: speed}) end
    :ok
  end

  def do_handle("move_relative", _) do
    {:error, "BAD_PARAMS",
      Poison.encode!(%{"x or y or z" => "number to move by", "speed" => "number"})}
  end

  # Read status
  def do_handle("read_status", _) do
    Logger.debug("Reporting Current Status")
    send_status
  end

  def do_handle("check_updates", _) do
    Fw.check_and_download_os_update
    :ok
  end

  def do_handle("check_arduino_updates", _) do
    Fw.check_and_download_fw_update
    :ok
  end

  def do_handle("reboot", _ ) do
    log("Bot Going down for reboot in 5 seconds", [], ["BotControl"])
    spawn fn ->
      log("Rebooting!", [:ticker, :warning_toast], ["BotControl"])
      Process.sleep(5000)
      Nerves.Firmware.reboot
    end
    :ok
  end

  def do_handle("power_off", _ ) do
    log("Bot Going down in 5 seconds. Pls remeber me.")
    spawn fn ->
      log("BOT OFFLINE", "error_ticker")
      Process.sleep(5000)
      Nerves.Firmware.poweroff
    end
    :ok
  end

  def do_handle("mcu_config_update", [params]) when is_map(params) do
    case Enum.all?(params, fn({param, value}) ->
      param_int = Gcode.parse_param(param)
      spawn fn -> Command.update_param(param_int, value) end
    end)
    do
      true ->
        log("MCU Params updated.", [], ["RPCHANDLER"])
        :ok
      false -> {:error, "mcu_config_update", "Something went wrong."}
    end
  end

  def do_handle("sync", _) do
    BotSync.sync
    :ok
  end

  def do_handle("exec_sequence", [sequence]) do
    cond do
      Map.has_key?(sequence, "body")
       and Map.has_key?(sequence, "args")
       and Map.has_key?(sequence, "name")
      ->
        GenServer.call(FarmEventManager, {:add, {:sequence, sequence}})
      true -> log("Sequence invalid.", [:error_toast], ["RPCHANDLER"])
    end
    :ok
  end

  def do_handle("start_regimen", [%{"regimen_id" => id}]) when is_integer(id) do
    BotSync.sync()
    regimen = BotSync.get_regimen(id)
    GenServer.call(FarmEventManager, {:add, {:regimen, regimen}})
    send_status
  end

  def do_handle("start_regimen", params) do
    Logger.debug("bad params for start_regimen: #{inspect params}")
    {:error, "BAD_PARAMS",
      Poison.encode!(%{"regimen_id" => "number"})}
  end

  def do_handle("stop_regimen", [%{"regimen_id" => id}]) when is_integer(id) do
    regimen = BotSync.get_regimen(id)
    running = GenServer.call(FarmEventManager, :state)
    |> Map.get(:running_regimens)
    |> Enum.find(fn({_p, re}) ->
      re == regimen
    end)
    send(FarmEventManager, {:done, {:regimen, running}})
    send_status
  end

  def do_handle("stop_regimen", params) do
    Logger.debug("bad params for stop_regimen: #{inspect params}")
    {:error, "BAD_PARAMS",
      Poison.encode!(%{"regimen_id" => "number"})}
  end



  # Unhandled event. Probably not implemented if it got this far.
  def do_handle(event, params) do
    Logger.debug("[RPC_HANDLER] got valid rpc, but event is not implemented.")
    {:error, "Unhandled method", "#{inspect {event, params}}"}
  end

  @doc """
    Shortcut for logging a message to the frontend.
    =  Channel can be  =
    |  :error_ticker   |
    |  :error_toast    |
    |  :success_toast  |
    |  :warning_toast  |
  """
  def log(message, channel \\ [], tags \\ [])
  def log(message, channels, tags)
  when is_bitstring(message)
   and is_list(channels)
   and is_list(tags) do
    @transport.emit(log_msg(message, channels, tags))
  end

  def send_status do
    status =
      Map.merge(BotState.get_status,
      %{ farm_events: GenServer.call(FarmEventManager, :jsonable) })
    m = %{id: nil,
          method: "status_update",
          params: [status] }
    @transport.emit(Poison.encode!(m))
  end
end
