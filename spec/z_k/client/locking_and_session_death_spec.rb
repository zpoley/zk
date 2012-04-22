require 'spec_helper'

shared_examples_for 'session death' do
  def deliver_session_event_to(event_num, zk)
    # jeez, Zookeeper callbacks are so frustratingly stupid
    bogus_event = ZookeeperCallbacks::WatcherCallback.new
    bogus_event.initialize_context(:type => -1, :state => event_num, :path => '', :context => 'bogustestevent')
    # XXX: this is bad because we're in the wrong thread, but we'll fix this after the next Zookeeper release
    zk.event_handler.process(bogus_event)
  end

  before do
    @other_zk = ZK.new(@connection_string)
  end

  after do
    @other_zk.close! unless @other_zk.closed?
  end

  it %[should wake up in the case of an expired session and throw an exception] do
    @a = false

    @other_zk.event_handler.register_state_handler(zoo_state) do |event|
      @a = event
    end

    th = Thread.new do
      @other_zk.block_until_node_deleted(@path)
    end

    # we don't expect an exception yet, so warn us if there is on while this
    # thread is on its way to sleep
    th.abort_on_exception = true

    wait_until(2) { th.status == 'sleep' }

    th.abort_on_exception = false   # after here, we're raising an exception on purpose

    th.join if th.status.nil?       # this indicates an exception happened...already

    # not on the other thread, this may be bad
    deliver_session_event_to(zoo_state, @other_zk)

    # ditto, this is probably happening synchrnously
    wait_until(2) { @a }.should be_true

    lambda { th.join(2) }.should raise_error(zoo_error_class)
  end
end # session death

shared_examples_for 'locking and session death' do
  describe 'exceptional conditions' do
    describe 'ZOO_EXPIRED_SESSION_STATE' do
      let(:zoo_state) { ZookeeperConstants::ZOO_EXPIRED_SESSION_STATE }
      let(:zoo_error_class) { ZookeeperExceptions::ZookeeperException::SessionExpired }

      it_behaves_like 'session death'
    end

    describe 'ZOO_CONNECTING_STATE' do
      let(:zoo_state) { ZookeeperConstants::ZOO_CONNECTING_STATE }
      let(:zoo_error_class) { ZookeeperExceptions::ZookeeperException::NotConnected }

      it_behaves_like 'session death'
    end

    describe 'ZOO_CLOSED_STATE' do
      let(:zoo_state) { ZookeeperConstants::ZOO_CLOSED_STATE }
      let(:zoo_error_class) { ZookeeperExceptions::ZookeeperException::ConnectionClosed }

      it_behaves_like 'session death'
    end
  end
end

describe 'threaded client and locking behavior' do
  include_context 'threaded client connection'

  before do
    @path = '/test'
    @zk.create('/test') rescue ZK::Exceptions::NodeExists
  end

  describe 'block_until_node_deleted' do
    it %[should raise an EventDispatchThreadException if called in the context of the event dispatch thread] do
      @exception = nil

      @zk.register(@path) do |event|
        @zk.event_dispatch_thread?.should be_true

        begin
          @zk.block_until_node_deleted(@path)
        rescue Exception => e
          @exception = e
        end
      end

      @zk.exists?(@path, :watch => true)

      @zk.set(@path, 'blah')

      wait_until(2) { @exception }.should be_kind_of(ZK::Exceptions::EventDispatchThreadException)
    end
  end

  it_should_behave_like 'locking and session death'
end

