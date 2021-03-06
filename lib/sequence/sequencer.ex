defmodule SequencerVM do
  require Logger


  def start_link(sequence) do
    GenServer.start_link(__MODULE__,sequence)
  end

  def init(sequence) do
    body = Map.get(sequence, "body")
    args = Map.get(sequence, "args")
    tv = Map.get(args, "tag_version") || 0
    BotSync.sync()
    corpus_module = BotSync.get_corpus(tv)
    {:ok, instruction_set} = corpus_module.start_link(self())
    status = BotState.get_status
    tick(self())
    initial_state =
      %{
        status: status,
        body: body,
        args: Map.put(args, "name", Map.get(sequence, "name")),
        instruction_set: instruction_set,
        vars: %{},
        running: true
       }
    {:ok, initial_state}
  end

  def handle_call({:set_var, identifier, value}, _from, state) do
    new_vars = Map.put(state.vars, identifier, value)
    new_state = Map.put(state, :vars, new_vars )
    {:reply, :ok, new_state }
  end

  def handle_call({:get_var, identifier}, _from, state ) do
    v = Map.get(state.vars, identifier, :error)
    {:reply, v, state }
  end

  def handle_call(:get_all_vars, _from, state ) do
    # Kind of dirty function to make mustache work properly.
    # Also possibly a huge memory leak.

    # get all of the local vars from the vm.
    thing1 = state.vars |> Enum.reduce(%{}, fn ({key, val}, acc) -> Map.put(acc, String.to_atom(key), val) end)

    # put current position into the Map
    [x,y,z] = BotState.get_current_pos
    pins = BotState.get_status
    |> Map.get(:pins)
    |> Enum.reduce(%{}, fn( {key, %{mode: _mode, value: val}}, acc) ->
      Map.put(acc, String.to_atom("pin"<>key), val)
    end)
    thing2 = Map.merge( %{x: x, y: y, z: z }, pins)

    # gets a couple usefull things out of BotSync
    thing3v = List.first Map.get(BotSync.fetch, "users")
    thing3 = thing3v |> Enum.reduce(%{}, fn ({key, val}, acc) -> Map.put(acc, String.to_atom(key), val) end)

    # Combine all the things.
    all_things = Map.merge(thing1, thing2) |> Map.merge(thing3)
    {:reply, all_things , state }
  end

  def handle_call(:pause, _from, state) do
    {:reply, self(), Map.put(state, :running, false)}
  end

  def handle_call(thing, _from, state) do
    RPCMessageHandler.log("#{inspect thing} is probably not implemented", [:warning_toast], ["Sequencer"])
    {:reply, :ok, state}
  end

  def handle_cast(:resume, state) do
    handle_info(:run_next_step, Map.put(state, :running, true))
  end

  # if the VM is paused
  def handle_info(:run_next_step, %{
          status: status,
          body: body,
          args: args,
          instruction_set: instruction_set,
          vars: vars,
          running: false
         })
  do
    {:noreply, %{status: status, body: body, args: args, instruction_set: instruction_set, vars: vars, running: false  }}
  end

  # if there is no more steps to run
  def handle_info(:run_next_step, %{
          status: status,
          body: [],
          args: args,
          instruction_set: instruction_set,
          vars: vars,
          running: running
         })
  do
    Logger.debug("sequence done")
    RPCMessageHandler.log("Sequence Complete", [], [Map.get(args, "name")])
    send(SequenceManager, {:done, self()})
    Logger.debug("Stopping VM")
    {:noreply, %{status: status, body: [], args: args, instruction_set: instruction_set, vars: vars, running: running  }}
  end

  # if there are more steps to run
  def handle_info(:run_next_step, %{
          status: status,
          body: body,
          args: args,
          instruction_set: instruction_set,
          vars: vars,
          running: true
         })
  do
    node = List.first(body)
    kind = Map.get(node, "kind")
    Logger.debug("doing: #{kind}")
    RPCMessageHandler.log("Doin step: #{kind}", [], [Map.get(args, "name")])
    GenServer.cast(instruction_set, {kind, Map.get(node, "args") })
    {:noreply, %{
            status: status,
            body: body -- [node],
            args: args,
            instruction_set: instruction_set,
            vars: vars,
            running: true
           }}
  end

  def tick(vm) do
    Process.send_after(vm, :run_next_step, 100)
  end

  def terminate(:normal, state) do
    GenServer.stop(state.instruction_set, :normal)
  end

  def terminate(reason, state) do
    Logger.debug("VM Died: #{inspect reason}")
    RPCMessageHandler.log("Sequence Finished with errors! #{inspect reason}", [:error_toast], ["Sequencer"])
    GenServer.stop(state.instruction_set, :normal)
    IO.inspect state
  end
end
