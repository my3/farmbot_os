defmodule Wifi do
  @dnsmasq_file Application.get_env(:fb, :dnsmasq_path)
  @env Mix.env
  use GenServer
  require Logger
  defp load do
    case SafeStorage.read(__MODULE__) do
      {:ok, {ssid, password} } -> {:wpa_supplicant, {ssid, password}}
      {:ok,:eth } -> :eth
      _ -> nil
    end
  end

  defp save({ssid, password}) do
    SafeStorage.write(__MODULE__, :erlang.term_to_binary({ssid, password}) )
  end

  defp save(:eth) do
    SafeStorage.write(__MODULE__, :erlang.term_to_binary(:eth))
  end

  def init(_args) do
    System.cmd("epmd", ["-daemon"])
    GenEvent.add_handler(Nerves.NetworkInterface.event_manager(), Network.EventManager, %{})
    initial_state = load
    case initial_state do
      {:wpa_supplicant, {ssid, pass}} -> start_wifi_client(ssid, pass)
                                       {:ok, {:wpa, connected: false}}
      :eth -> start_ethernet
                                       {:ok, {:wpa, connected: false}}
      _ -> start_hostapd_deps(@env) # These only need to be started onece per boot
           start_hostapd(@env)
           {:ok, :hostapd}
    end
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  defp start_wifi_client(ssid, pass) when is_bitstring(ssid) and is_bitstring(pass) do
     spawn_link fn -> Nerves.InterimWiFi.setup "wlan0", ssid: ssid, key_mgmt: :"WPA-PSK", psk: pass end
  end

  defp start_ethernet do
    spawn_link fn -> Nerves.InterimWiFi.setup "eth0" end
  end

  # Blatently ripped off from @joelbyler
  # https://github.com/joelbyler/elixir_conf_chores/blob/f13298f9185b850fdfaad0448f03a03b3067a85c/apps/firmware/lib/firmware.ex
  defp start_hostapd_deps(:prod) do
    System.cmd("ip", ["link", "set", "wlan0", "up"]) |> print_cmd_result
    System.cmd("ip", ["addr", "add", "192.168.24.1/24", "dev", "wlan0"]) |> print_cmd_result
    System.cmd("dnsmasq", ["--dhcp-lease", @dnsmasq_file]) |> print_cmd_result
  end

  defp start_hostapd_deps(_) do
    nil
  end

  defp start_hostapd(:prod) do
    System.cmd("hostapd", ["-B", "-d", "/etc/hostapd/hostapd.conf"]) |> print_cmd_result
  end

  defp start_hostapd(_) do
    nil
  end

  defp print_cmd_result({message, 0}) do
    # IO.puts message
    message
  end

  defp print_cmd_result({message, err_no}) do
    Logger.error("Command failed! (#{inspect err_no}) #{inspect message}")
    raise "This is probably not recoverable. Bailing"
  end

  def connect(ssid, pass) do
    save({ssid, pass})
    GenServer.cast(__MODULE__, {:connect, ssid, pass})
  end

  def connect(:eth) do
    save(:eth)
    GenServer.cast(__MODULE__, {:connect, :eth})
  end

  def set_connected(con) when is_boolean(con) do
    GenServer.cast(__MODULE__, {:connected, con})
  end

  def scan do
    GenServer.call(__MODULE__, :scan, 10000)
  end

  def connected? do
    GenServer.call(__MODULE__, :am_i_connected)
  end

  def handle_cast({:connect, ssid, pass}, :hostapd) do
    Logger.debug("trying to switch from hostapd to wpa_supplicant ")
    System.cmd("sh", ["-c", "killall hostapd"]) |> print_cmd_result
    System.cmd("sh", ["-c", "killall dnsmasq"]) |> print_cmd_result
    File.rm(@dnsmasq_file)
    System.cmd("ip", ["link", "set", "wlan0", "down"]) |> print_cmd_result
    System.cmd("ip", ["addr", "del", "192.168.24.1/24", "dev", "wlan0"]) |> print_cmd_result
    System.cmd("ip", ["link", "set", "wlan0", "up"]) |> print_cmd_result
    start_wifi_client(ssid, pass)
    {:noreply, :hostapd}
  end

  def handle_cast({:connect, :eth}, :hostapd) do
    Logger.debug("trying to switch from hostapd to ethernet ")
    System.cmd("sh", ["-c", "killall hostapd"]) |> print_cmd_result
    System.cmd("sh", ["-c", "killall dnsmasq"]) |> print_cmd_result
    File.rm(@dnsmasq_file)
    System.cmd("ip", ["link", "set", "wlan0", "down"]) |> print_cmd_result
    System.cmd("ip", ["addr", "del", "192.168.24.1/24", "dev", "wlan0"]) |> print_cmd_result
    System.cmd("ip", ["link", "set", "wlan0", "up"]) |> print_cmd_result
    start_ethernet
    {:noreply, :hostapd}
  end

  def handle_cast({:connect, ssid, pass}, {:wpa, connected: _con}) do
    start_wifi_client(ssid, pass)
    {:noreply,{ssid, pass, connected: false}}
  end

  def handle_cast({:connect, :eth}, {:wpa, connected: _con}) do
    start_ethernet
    {:noreply, {:eth, connected: false} }
  end

  def handle_cast({:connected, con}, {:wpa, connected: _old}) do
    {:noreply, {:wpa, connected: con} }
  end

  def handle_cast({:connected, con}, :hostapd) do
    {:noreply, {:wpa, connected: con} }
  end

  def handle_call(:scan, _from, {:wpa, connected: are_connected} ) do
    {hc, 0} = System.cmd("iw", ["wlan0", "scan", "ap-force"])
    {:reply, hc |> clean_ssid, {:wpa, connected: are_connected}}
  end

  def handle_call(:scan, _from, :hostapd ) do
    {hc, 0} = System.cmd("iw", ["wlan0", "scan", "ap-force"])
    {:reply, hc |> clean_ssid, :hostapd}
  end

  # IF hostapd always no.
  def handle_call(:am_i_connected, _from, :hostapd) do
    case @env do
      :prod -> {:reply, false, :hostapd}
      _ -> {:reply, true, :hostapd}
    end
  end

  def handle_call(:am_i_connected, _from, {:wpa, connected: are_connected}) do
    {:reply, are_connected, {:wpa, connected: are_connected}}
  end

  def handle_call(:get_state, _crom, state) do
    {:reply, state, state}
  end

  defp clean_ssid(hc) do
    hc
    |> String.replace("\t", "")
    |> String.replace("\\x00", "")
    |> String.split("\n")
    |> Enum.filter(fn(s) -> String.contains?(s, "SSID") end)
    |> Enum.map(fn(z) -> String.replace(z, "SSID: ", "") end)
    |> Enum.filter(fn(z) -> String.length(z) != 0 end)
  end

  def terminate(reason, state) do
    Logger.debug("Networking died.")
    IO.inspect reason
    IO.inspect state
    System.cmd("sh", ["-c", "killall hostapd"]) |> print_cmd_result
    System.cmd("sh", ["-c", "killall dnsmasq"]) |> print_cmd_result
    System.cmd("sh", ["-c", "killall httpd"]) |> print_cmd_result
  end
end
