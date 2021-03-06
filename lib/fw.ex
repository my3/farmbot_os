defmodule Fw do
  require Logger
  use Supervisor
  @env Mix.env
  @target System.get_env("NERVES_TARGET") || "rpi3"
  @bot_state_save_file Application.get_env(:fb, :bot_state_save_file)
  @version Path.join(__DIR__ <> "/..", "VERSION") |> File.read! |> String.strip

  def init(_args) do
    children = [
      worker(SafeStorage, [[]], restart: :permanent),
      worker(BotState, [[]], restart: :permanent ),
      worker(SSH, [@env], restart: :permanent),
      supervisor(Extras, [[]], restart: :temporary),
      supervisor(NetworkSupervisor, [[]], restart: :permanent),
      supervisor(Controller, [[]], restart: :permanent)
    ]
    opts = [strategy: :one_for_one, name: Fw]
    supervise(children, opts)
  end

  def start(_type, args) do
    File.write("/tmp/resolv.conf", "nameserver 8.8.8.8\n nameserver 8.8.4.4\n ")
    Logger.debug("Starting Firmware on Target: #{@target}")
    Supervisor.start_link(__MODULE__, args)
  end

  def version do
    @version
  end

  def factory_reset do
    GenServer.stop SafeStorage, :reset
    Nerves.Firmware.reboot
  end

  @doc """
    Looks for the latest asset of given extension (ie: ".exe")
    on a Github Release API.
    Returns {:update, url_to_latest_download} or :no_updates
    TODO: Rewrite this using 'with'
  """
  def check_updates(url, extension) when is_bitstring(extension) do
    Logger.debug(url)
    resp = HTTPotion.get url,
    [headers: ["User-Agent": "Farmbot"]]
    current_version = Fw.version
    case resp do
      %HTTPotion.ErrorResponse{message: error} ->
        RPCMessageHandler.log("Update check failed: #{inspect error}", [:error_toast], ["BotUpdates"])
        {:error, "Check Updates failed", error}
      %HTTPotion.Response{body: body,
                          headers: _headers,
                          status_code: 200} ->
        json = Poison.decode!(body)
        "v"<>new_version = Map.get(json, "tag_name")
        new_version_url = Map.get(json, "assets")
        |> Enum.find(fn asset ->
                     String.contains?(Map.get(asset, "browser_download_url"),
                                            extension) end)
        |> Map.get("browser_download_url")
        Logger.debug("new version: #{new_version}, current_version: #{current_version}")
        case (new_version != current_version) do
          true ->
            RPCMessageHandler.log("New update available!", [:success_toast, :ticker], ["BotUpdates"])
            {:update, new_version_url}
          _ ->
            RPCMessageHandler.log("Bot up to date!", [:success_toast, :ticker], ["BotUpdates"])
            :no_updates
        end

      %HTTPotion.Response{body: body,
                          headers: _headers,
                          status_code: 301} ->
        msg = Poison.decode!(body)
        Map.get(msg, "url") |> check_updates(extension)
    end
  end

  @doc """
    Shortcut for check_updates
  """
  def check_os_updates do
    check_updates(
    Map.get(Auth.get_token, "unencoded") |> Map.get("os_update_server"),
    ".fw")
  end

  @doc """
    Shortcut for check_updates
  """
  def check_fw_updates do
    check_updates(
    Map.get(Auth.get_token, "unencoded") |> Map.get("fw_update_server"),
     ".hex")
  end

  def check_and_download_os_update do
    case Fw.check_os_updates do
      :no_updates ->  RPCMessageHandler.log("Bot OS up to date!", [:success_toast, :ticker], ["BotUpdates"])
       {:update, url} ->
         Logger.debug("NEW OS UPDATE")
         spawn fn -> Downloader.download_and_install_os_update(url) end
       {:error, message} ->
         RPCMessageHandler.log("Error fetching update: #{message}", [:error_toast], ["BotUpdates"])
       error ->
         RPCMessageHandler.log("Error fetching update: #{inspect error}", [:error_toast], ["BotUpdates"])
    end
  end

  def check_and_download_fw_update do
    case Fw.check_fw_updates do
      :no_updates -> RPCMessageHandler.log("Bot FW up to date!", [:success_toast, :ticker], ["BotUpdates"])
       {:update, url} ->
          Logger.debug("NEW FIRMWARE UPDATE")
          spawn fn -> Downloader.download_and_install_fw_update(url) end
      {:error, message} -> RPCMessageHandler.log("Error fetching update: #{message}", [:error_toast], ["BotUpdates"])
    end
  end
end
