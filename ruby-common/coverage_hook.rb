# Coverage instrumentation for long-running Ruby apps (Redmine etc.).
#
# Loaded as a Rails initializer; starts Ruby's stdlib `Coverage` tracker
# at boot and spawns a flusher thread that snapshots the in-memory map
# to ${TRACELIB_COVERAGE_DIR}/coverage.json every N seconds (default 15).
# `coverage_report.sh` reads the snapshot back and emits a one-line
# summary in the same shape as the PHP/Go aggregators.
#
# We use `Coverage.peek_result` (Ruby >= 2.6), which returns a snapshot
# without stopping the tracker — important so live requests keep
# accumulating between flushes.

require 'coverage'
require 'json'
require 'fileutils'

unless ENV['TRACELIB_COVERAGE_DISABLE'] == '1'
  Coverage.start unless Coverage.running?

  cov_dir = ENV['TRACELIB_COVERAGE_DIR'] || '/coverage'
  reset_file = ENV['TRACELIB_COVERAGE_RESET_FILE'] || File.join(cov_dir, 'reset.request')
  interval = (ENV['TRACELIB_COVERAGE_INTERVAL_SECONDS'] || '15').to_i
  interval = 15 if interval <= 0

  FileUtils.mkdir_p(cov_dir) rescue nil

  module TracelibCoverageRuntime
    class << self
      attr_accessor :cov_dir, :reset_file
    end
  end
  TracelibCoverageRuntime.cov_dir = cov_dir
  TracelibCoverageRuntime.reset_file = reset_file

  def TracelibCoverageRuntime.flush
    begin
      result = Coverage.peek_result
      tmp = File.join(self.cov_dir, 'coverage.json.tmp')
      File.open(tmp, 'w') { |f| f.write(JSON.generate(result)) }
      File.rename(tmp, File.join(self.cov_dir, 'coverage.json'))
    rescue => e
      warn "[tracelib-coverage] flush failed: #{e.class}: #{e.message}"
    end
  end

  def TracelibCoverageRuntime.reset_if_requested
    return unless self.reset_file && File.exist?(self.reset_file)
    begin
      Coverage.result(stop: false, clear: true)
      File.delete(self.reset_file) if self.reset_file && File.exist?(self.reset_file)
    rescue => e
      warn "[tracelib-coverage] reset failed: #{e.class}: #{e.message}"
    end
  end

  class TracelibCoverageMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      TracelibCoverageRuntime.reset_if_requested
      @app.call(env)
    ensure
      TracelibCoverageRuntime.flush
    end
  end

  if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
    Rails.application.config.middleware.insert_before(0, TracelibCoverageMiddleware)
  end

  Thread.new do
    sleep 5
    loop do
      TracelibCoverageRuntime.flush
      sleep interval
    end
  end

  trap('USR1') do
    if reset_file && File.exist?(reset_file)
      TracelibCoverageRuntime.reset_if_requested
    else
      TracelibCoverageRuntime.flush
    end
  end rescue nil

  STDERR.puts "[tracelib-coverage] started, dir=#{cov_dir} interval=#{interval}s pid=#{Process.pid}"
end
