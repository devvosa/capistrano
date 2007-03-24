require "#{File.dirname(__FILE__)}/../utils"
require 'capistrano/configuration/execution'
require 'capistrano/task_definition'

class ConfigurationExecutionTest < Test::Unit::TestCase
  class MockConfig
    attr_reader :tasks, :namespaces, :fully_qualified_name, :parent
    attr_reader :state, :original_initialize_called
    attr_accessor :logger, :default_task

    def initialize(options={})
      @original_initialize_called = true
      @tasks = {}
      @namespaces = {}
      @state = {}
      @fully_qualified_name = options[:fqn]
      @parent = options[:parent]
      @logger = options.delete(:logger)
    end

    include Capistrano::Configuration::Execution
  end

  def setup
    @config = MockConfig.new(:logger => stub(:debug => nil, :info => nil, :important => nil))
    @config.stubs(:search_task).returns(nil)
  end

  def test_initialize_should_initialize_collections
    assert_nil @config.rollback_requests
    assert @config.original_initialize_called
    assert @config.task_call_frames.empty?
  end

  def test_execute_task_should_populate_call_stack
    task = new_task @config, :testing
    assert_nothing_raised { @config.execute_task(task) }
    assert_equal %w(testing), @config.state[:testing][:stack]
    assert_nil @config.state[:testing][:history]
    assert @config.task_call_frames.empty?
  end

  def test_nested_execute_task_should_add_to_call_stack
    testing = new_task @config, :testing
    outer = new_task(@config, :outer) { execute_task(testing) }

    assert_nothing_raised { @config.execute_task(outer) }
    assert_equal %w(outer testing), @config.state[:testing][:stack]
    assert_nil @config.state[:testing][:history]
    assert @config.task_call_frames.empty?
  end

  def test_execute_task_should_execute_before_hook_if_defined
    testing = new_task @config, :testing
    before = new_task @config, :before_testing
    @config.expects(:search_task).with("before_testing").returns(before)
    @config.execute_task(testing)
    assert_equal %w(before_testing testing), @config.state[:trail]
  end

  def test_execute_task_should_execute_after_hook_if_defined
    testing = new_task @config, :testing
    after = new_task @config, :after_testing
    @config.expects(:search_task).with("after_testing").returns(after)
    @config.execute_task(testing)
    assert_equal %w(testing after_testing), @config.state[:trail]
  end

  def test_execute_task_should_execute_in_scope_of_tasks_parent
    ns = stub("namespace", :tasks => {}, :default_task => nil, :fully_qualified_name => "ns")
    ns.expects(:instance_eval)
    ns.expects(:search_task).returns(nil).times(2) # before and after hooks
    testing = new_task ns, :testing
    @config.execute_task(testing)
  end

  def test_transaction_outside_of_task_should_raise_exception
    assert_raises(ScriptError) { @config.transaction {} }
  end

  def test_transaction_without_block_should_raise_argument_error
    testing = new_task(@config, :testing) { transaction }
    assert_raises(ArgumentError) { @config.execute_task(testing) }
  end

  def test_transaction_should_initialize_transaction_history
    @config.state[:inspector] = stack_inspector
    testing = new_task(@config, :testing) { transaction { instance_eval(&state[:inspector]) } }
    @config.execute_task(testing)
    assert_equal [], @config.state[:testing][:history]
  end

  def test_transaction_from_within_transaction_should_not_start_new_transaction
    third = new_task(@config, :third, &stack_inspector)
    second = new_task(@config, :second) { transaction { execute_task(third) } }
    first = new_task(@config, :first) { transaction { execute_task(second) } }
    # kind of fragile...not sure how else to check that transaction was only
    # really run twice...but if the transaction was REALLY run, logger.info
    # will be called once when it starts, and once when it finishes.
    @config.logger = mock()
    @config.logger.stubs(:debug)
    @config.logger.expects(:info).times(2)
    @config.execute_task(first)
  end

  def test_exception_raised_in_transaction_should_call_all_registered_rollback_handlers_in_reverse_order
    aaa = new_task(@config, :aaa) { on_rollback { (state[:rollback] ||= []) << :aaa } }
    bbb = new_task(@config, :bbb) { on_rollback { (state[:rollback] ||= []) << :bbb } }
    ccc = new_task(@config, :ccc) {}
    ddd = new_task(@config, :ddd) { on_rollback { (state[:rollback] ||= []) << :ddd }; execute_task(bbb); execute_task(ccc) }
    eee = new_task(@config, :eee) { transaction { execute_task(ddd); execute_task(aaa); raise "boom" } }
    assert_raises(RuntimeError) do
      @config.execute_task(eee)
    end
    assert_equal [:aaa, :bbb, :ddd], @config.state[:rollback]
    assert_nil @config.rollback_requests
    assert @config.task_call_frames.empty?
  end

  def test_exception_during_rollback_should_simply_be_logged_and_ignored
    aaa = new_task(@config, :aaa) { on_rollback { state[:aaa] = true; raise LoadError, "ouch" }; execute_task(bbb) }
    bbb = new_task(@config, :bbb) { raise MadError, "boom" }
    ccc = new_task(@config, :ccc) { transaction { execute_task(aaa) } }
    assert_raises(NameError) do
      @config.execute_task(ccc)
    end
    assert @config.state[:aaa]
  end

  def test_find_and_execute_task_should_raise_error_when_task_cannot_be_found
    @config.expects(:find_task).with("path:to:task").returns(nil)
    assert_raises(Capistrano::NoSuchTaskError) { @config.find_and_execute_task("path:to:task") }
  end

  def test_find_and_execute_task_should_execute_task_when_task_is_found
    @config.expects(:find_task).with("path:to:task").returns(:found)
    @config.expects(:execute_task).with(:found)
    assert_nothing_raised { @config.find_and_execute_task("path:to:task") }
  end
  private

    def stack_inspector
      Proc.new do
        (state[:trail] ||= []) << current_task.fully_qualified_name
        data = state[current_task.name] = {}
        data[:stack] = task_call_frames.map { |frame| frame.task.fully_qualified_name }
        data[:history] = rollback_requests && rollback_requests.map { |frame| frame.task.fully_qualified_name }
      end
    end

    def new_task(namespace, name, options={}, &block)
      block ||= stack_inspector
      namespace.tasks[name] = Capistrano::TaskDefinition.new(name, namespace, &block)
    end
end