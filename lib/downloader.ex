defmodule Downloader do
  @log_tag "BotUpdates"
  def download_and_install_os_update(url) do
    RPCMessageHandler.log("Downloading OS update!", [:warning_toast], [@log_tag])
    File.rm("/tmp/update.fw")
    run(url, "/tmp/update.fw") |> Nerves.Firmware.upgrade_and_finalize
    RPCMessageHandler.log("Going down for OS update!", [:warning_toast], [@log_tag])
    Process.sleep(5000)
    Nerves.Firmware.reboot
  end

  def download_and_install_fw_update(url) do
    RPCMessageHandler.log("Downloading FW Update", [:warning_toast], [@log_tag])
    File.rm("/tmp/update.hex")
    file = run(url, "/tmp/update.hex")
    RPCMessageHandler.log("Installing FW Update", [], [@log_tag])
    GenServer.cast(UartHandler, {:update_fw, file})
  end

  def run(url, dl_file) when is_bitstring url do
    HTTPotion.get url, stream_to: self, timeout: :infinity
    receive_data(total_bytes: :unknown, data: "", dl_path: dl_file)
  end

  defp receive_data(total_bytes: total_bytes, data: data, dl_path: path) do
    receive do
      %HTTPotion.AsyncHeaders{headers: h} ->

        {total_bytes, _} = h[:"Content-Length"] |> Integer.parse
        IO.puts "Let's download #{mb total_bytes}…"
        receive_data(total_bytes: total_bytes, data: data, dl_path: path)

      %HTTPotion.AsyncChunk{chunk: new_data} ->

        accumulated_data = data <> new_data
        accumulated_bytes = byte_size(accumulated_data)
        percent = accumulated_bytes / total_bytes * 100 |> Float.round(2)
        IO.puts "#{percent}% (#{mb accumulated_bytes})"
        receive_data(total_bytes: total_bytes, data: accumulated_data, dl_path: path)

      %HTTPotion.AsyncEnd{} ->

        File.write!(path, data)
        IO.puts "All downloaded! See: #{path}"
        path

    end
  end

  defp mb(bytes) do
    number = bytes / 1_048_576 |> Float.round(2)
    "#{number} MB"
  end
end
