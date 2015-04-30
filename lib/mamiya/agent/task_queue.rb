require 'mamiya/agent'
require 'thread'

# XXX: TODO: have to refactor
module Mamiya
  class Agent
    class TaskQueue
      class Stopped < Exception; end
      GRACEFUL_TIMEOUT = 30
      JOIN_TIMEOUT = 30

      def initialize(agent, task_classes: [], logger: Mamiya::Logger.new)
        @agent = agent
        @task_classes = task_classes
        @external_queue = Queue.new
        @queues = {}
        @worker_threads = nil
        @statuses = nil
        @queueing_thread = nil
        @lifecycle_mutex = Mutex.new
        @terminate = false
        @logger = logger.with_clean_progname['task_queue']
      end

      attr_reader :worker_threads, :task_classes, :agent

      def start!
        @lifecycle_mutex.synchronize do
          return if running?

          worker_threads = {}
          queues = {}
          statuses = {}

          @task_classes.each { |klass|
            name = klass.identifier.to_sym
            queue = queues[name] = Queue.new
            statuses[name] = {pending: [], lock: Mutex.new}
            th = worker_threads[name] = Thread.new(
              klass, queue,
              statuses[name],
              &method(:worker_loop)
            )
            th.abort_on_exception = true
          }

          @terminate = false
          @statuses = statuses 
          @queues = queues
          exqueue = @external_queue = Queue.new
          @queueing_thread = Thread.new(queues, exqueue, statuses, &method(:queueing_loop))
          @queueing_thread.abort_on_exception = true
          @worker_threads = worker_threads
        end
      end

      def stop!(graceful = false)
        @lifecycle_mutex.synchronize do
          return unless running?
          @terminate = true
          @queueing_thread.kill if @queueing_thread.alive?
          if graceful
            @worker_threads.each do |th|
              th.join(GRACEFUL_TIMEOUT)
            end
          end
          @worker_threads.each do |name, th|
            next unless th.alive?
            th.kill
            th.join(JOIN_TIMEOUT) 
          end
          @queues = nil
          @worker_threads = nil
        end
      end

      def running?
        @worker_threads && !@terminate
      end

      def working?
        running? && status.any? { |name, stat| stat[:working] }
      end

      def enqueue(task_name, task)
        raise Stopped, 'this task queue is stopped' unless running?

        if task['_labels'] && !agent.match?(task['_labels'])
          @logger.debug "skipping enqueue #{task_name.inspect}, #{task.inspect}, because agent doesn't match"
          return self
        end

        if task['_agents'] && !task['_agents'].include?(agent.name)
          @logger.debug "skipping enqueue #{task_name.inspect}, #{task.inspect}, because agent name doesn't match"
          return self
        end

        task.delete '_labels'
        task.delete '_agents'
        task.delete 'task'
        task['task'] = task_name

        @logger.debug "enqueue #{task_name.inspect}, #{task.inspect}, #{@external_queue.inspect}"
        @external_queue << [task_name, task]
        self
      end

      def status
        return nil unless running?
        Hash[@statuses.map do |name, st|
          [name, {
            queue: st[:pending].dup,
            working: st[:working] ? st[:working].dup : nil,
          }]
        end]
      end

      private

      def worker_loop(task_class, queue, status)
        while task = queue.pop
          break if @terminate
          begin
            status[:lock].synchronize do
              status[:pending].delete task

              task['start'] = Time.now.to_i
              status[:working] = task
            end
            task_logger = @logger.with_clean_progname
            task_class.new(self, task, agent: @agent, logger: task_logger).execute
          rescue Exception => e
            @logger.error "#{task_class} worker catched error: #{e}\n\t#{e.backtrace.join("\n\t")}"
          ensure
            status[:lock].synchronize do
              status[:working] = nil
            end
          end
          break if @terminate
        end
      end

      def queueing_loop(queues, external_queue, statuses)
        @logger.debug "queueing thread started #{external_queue.inspect}"
        while _ = external_queue.pop
          task_name, task = _

          break if @terminate

          queue = queues[task_name]
          unless queue
            @logger.debug "Ignoring task #{task_name} (queue not defined)"
            next
          end

          statuses[task_name][:lock].synchronize do
            statuses[task_name][:pending] << task
          end
          @logger.info "Queueing task #{task_name}: #{task.inspect}"
          queue << task
          break if @terminate
        end
        @logger.debug "queueing thread finish"
      rescue Exception => e
        @logger.error "queueing thread error #{e.inspect}\n\t#{e.backtrace.join("\n\t")}"
        raise e
      end
    end
  end
end
