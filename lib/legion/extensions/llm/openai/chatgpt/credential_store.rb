# frozen_string_literal: true

require 'base64'
require 'securerandom'
require 'legion/json'
require 'legion/logging'
require_relative 'error'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # Persists private credentials with owned paths, stable locks and atomic replacement.
          class CredentialStore
            MAX_RECORD_BYTES = 262_144
            BUNDLE_FIELDS = %i[access_token refresh_token expires_at account_id workspace_id residency].freeze
            RECORD_FIELDS = (BUNDLE_FIELDS + %i[schema_version instance auth_mode status generation
                                                login_generation]).freeze

            def initialize(root: nil)
              @root = root || File.join(Dir.home, '.legionio', 'auth', 'llm', 'openai')
              @protected_root = root ? @root : File.join(Dir.home, '.legionio', 'auth')
              validate_root
            end

            # These records are private. Auth owns the public, token-free projection.
            def read(instance:)
              with_lock(instance: instance, create: false) { read_record(instance: instance) }
            end

            def records
              return {} unless prepare_directory(create: false)

              Dir.children(@root).each_with_object({}) do |filename, result|
                next unless filename.end_with?('.json')

                instance = filename_instance(filename: filename)
                record = read(instance: instance)
                result[instance] = record if record && record[:status] != 'missing'
              end
            rescue ArgumentError, SystemCallError, IOError
              storage_error!
            end

            def begin_login(instance:, check: nil)
              with_lock(instance: instance, create: true, check: check) do
                record = read_record(instance: instance) || empty_record(instance: instance)
                generation = SecureRandom.hex(32)
                write_record(instance: instance, record: record.merge(login_generation: generation))
                generation
              end
            end

            def complete_login(instance:, generation:, bundle:, check: nil)
              with_lock(instance: instance, create: false, check: check) do
                record = read_record(instance: instance)
                validate_login_generation(record: record, generation: generation)
                replacement = empty_record(instance: instance).merge(bundle.slice(*BUNDLE_FIELDS),
                                                                     status: 'authenticated')
                write_record(instance: instance, record: replacement)
                replacement
              end || raise(
                Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT login was disconnected; start login again', kind: :authentication
                ), cause: nil
              )
            end

            # The lock is a stable inode, shared by refresh, replacement and logout.
            # Holding it across the refresh exchange gives exactly one rotating writer.
            def refresh_credentials(instance:, &)
              result = with_lock(instance: instance, create: false) do
                record = read_record(instance: instance)
                require_authenticated(record: record)
                bundle = refresh_bundle(instance: instance, record: record, &)
                replacement = record.merge(bundle.slice(*BUNDLE_FIELDS))
                write_record(instance: instance, record: replacement) unless replacement == record
                replacement.slice(*BUNDLE_FIELDS)
              end
              return result if result

              require_authenticated(record: nil)
            end

            def logout(instance:)
              with_lock(instance: instance, create: true) do
                # A token-free tombstone invalidates browser/device flows already in flight.
                write_record(instance: instance, record: empty_record(instance: instance))
              end
              nil
            end

            private

            def validate_root
              storage_error! unless @root.is_a?(String) && @root.valid_encoding? && @root.encoding.ascii_compatible?
              validate_root_path
            end

            def validate_root_path
              unless @root.start_with?('/') && @root != '/' && !@root.split('/').intersect?(%w[. ..]) &&
                     !@root.include?("\0") && File.expand_path(@root) == @root
                storage_error!
              end
            end

            def filename_instance(filename:)
              instance = Base64.urlsafe_decode64(filename.delete_suffix('.json')).force_encoding(Encoding::UTF_8)
              storage_error! unless filename == "#{instance_key(instance: instance)}.json"
              instance
            end

            def validate_login_generation(record:, generation:)
              return if record && generation.is_a?(String) && generation.match?(/\A[0-9a-f]{64}\z/) &&
                        record[:login_generation] == generation

              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT login was superseded or disconnected; start login again', kind: :authentication
              ), cause: nil
            end

            def require_authenticated(record:)
              return if record && record[:status] == 'authenticated'

              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT login is required for this instance', kind: :authentication
              ), cause: nil
            end

            def refresh_bundle(instance:, record:)
              yield record.slice(*BUNDLE_FIELDS)
            rescue Legion::Extensions::Llm::Openai::Chatgpt::Error => e
              if e.metadata[:reauth_required]
                replacement = record.except(*BUNDLE_FIELDS).merge(
                  status: 'reauth_required', account_id: record[:account_id], workspace_id: record[:workspace_id]
                )
                write_record(instance: instance, record: replacement)
              end
              raise e, cause: nil
            end

            def empty_record(instance:)
              { schema_version: 1, instance: instance, auth_mode: 'chatgpt', status: 'missing',
                generation: SecureRandom.hex(32) }
            end

            def instance_key(instance:)
              unless valid_instance?(instance: instance)
                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT instance must be a nonempty UTF-8 name of at most 160 bytes ' \
                           'without control characters', kind: :invalid_request
                ), cause: nil
              end
              Base64.urlsafe_encode64(instance, padding: false)
            end

            def valid_instance?(instance:)
              instance.is_a?(String) && (instance.encoding == Encoding::UTF_8 || instance.ascii_only?) &&
                instance.valid_encoding? && instance.bytesize.between?(1, 160) && !instance.match?(/[[:cntrl:]]/)
            end

            def prepare_directory(create:)
              path = ''
              @root.split('/').reject(&:empty?).each do |component|
                path = "#{path}/#{component}"
                info = directory_info(path: path, create: create)
                return false unless info

                validate_directory(info: info, path: path)
              end
              true
            rescue SystemCallError, IOError
              storage_error!
            end

            def directory_info(path:, create:)
              File.lstat(path)
            rescue Errno::ENOENT
              Legion::Logging.debug('ChatGPT credential directory does not exist')
              return nil unless create

              begin
                Dir.mkdir(path, 0o700)
              rescue Errno::EEXIST
                # Another process created the directory; validate its actual state.
                Legion::Logging.debug('ChatGPT credential directory creation raced; validating directory')
              end
              File.lstat(path)
            end

            def validate_directory(info:, path:)
              validate_directory_owner(info: info)
              if path == @protected_root || path.start_with?("#{@protected_root}/")
                storage_error! unless info.uid == ::Process.euid && info.mode & 0o7777 == 0o700
              else
                validate_ancestor(info: info)
              end
            end

            def validate_directory_owner(info:)
              storage_error! unless info.directory? && !info.symlink? && [0, ::Process.euid].include?(info.uid)
            end

            def validate_ancestor(info:)
              return if info.mode.nobits?(0o022)

              storage_error! unless info.uid.zero? && info.mode.anybits?(0o1000)
            end

            def with_lock(instance:, create:, check: nil, &)
              key = instance_key(instance: instance)
              return nil unless prepare_directory(create: create)

              path = File.join(@root, "#{key}.lock")
              flags = File::RDWR | File::NOFOLLOW
              flags |= File::CREAT if create
              opened = false
              File.open(path, flags, 0o600) do |lock|
                opened = true
                locked_operation(lock: lock, path: path, check: check, &)
              end
            rescue Errno::ENOENT
              storage_error! if opened
              missing_lock(key: key)
            rescue SystemCallError, IOError
              storage_error!
            end

            def missing_lock(key:)
              path = File.join(@root, "#{key}.json")
              storage_error! if File.exist?(path) || File.symlink?(path)
              Legion::Logging.debug('ChatGPT instance has no credential lock')
              nil
            end

            def locked_operation(lock:, path:, check:)
              validate_file(file: lock, path: path)
              acquire_lock(lock: lock, check: check)
              prepare_directory(create: false) || storage_error!
              validate_file(file: lock, path: path)
              check&.call
              result = yield
              validate_file(file: lock, path: path)
              result
            end

            def acquire_lock(lock:, check:)
              unless check
                lock.flock(File::LOCK_EX)
                return
              end
              until lock.flock(File::LOCK_EX | File::LOCK_NB)
                check.call
                sleep(0.05)
              end
              check.call
            end

            def validate_file(file:, path:)
              info = file.stat
              unless info.file? && info.uid == ::Process.euid && info.nlink == 1 && info.mode & 0o7777 == 0o600
                storage_error!
              end
              validate_inode(info: info, path: path)
            end

            def validate_inode(info:, path:)
              actual = File.lstat(path)
              storage_error! unless !actual.symlink? && info.dev == actual.dev && info.ino == actual.ino
            end

            def read_record(instance:)
              path = File.join(@root, "#{instance_key(instance: instance)}.json")
              opened = false
              File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
                opened = true
                validate_file(file: file, path: path)
                storage_error! if file.stat.size > MAX_RECORD_BYTES
                record = Legion::JSON.load(file.read(MAX_RECORD_BYTES + 1))
                validate_record(record: record, instance: instance)
                record
              end
            rescue Errno::ENOENT
              raise if opened

              Legion::Logging.debug('ChatGPT instance has no credential record')
              nil
            rescue Legion::JSON::ParseError, ArgumentError
              storage_error!
            end

            def validate_record(record:, instance:)
              validate_record_header(record: record, instance: instance)
              if record.key?(:login_generation) && !record[:login_generation].to_s.match?(/\A[0-9a-f]{64}\z/)
                storage_error!
              end
              validate_record_bundle(record: record)
              %i[account_id workspace_id residency].each do |field|
                storage_error! unless record[field].nil? || safe_identity?(value: record[field])
              end
            end

            def validate_record_header(record:, instance:)
              unless record.is_a?(Hash) && (record.keys - RECORD_FIELDS).empty? && record[:schema_version] == 1 &&
                     record[:instance] == instance && record[:auth_mode] == 'chatgpt'
                storage_error!
              end
              validate_record_state(record: record)
            end

            def validate_record_state(record:)
              unless %w[missing authenticated reauth_required].include?(record[:status]) &&
                     record[:generation].is_a?(String) && record[:generation].match?(/\A[0-9a-f]{64}\z/)
                storage_error!
              end
            end

            def validate_record_bundle(record:)
              if record[:status] == 'authenticated'
                validate_authenticated_bundle(record: record)
              elsif %i[access_token refresh_token expires_at residency].any? { |field| record.key?(field) }
                storage_error!
              end
            end

            def validate_authenticated_bundle(record:)
              storage_error! unless BUNDLE_FIELDS.all? { |field| record.key?(field) }
              validate_saved_tokens(record: record)
              validate_saved_expiry(expires: record[:expires_at])
              storage_error! unless safe_identity?(value: record[:account_id])
            end

            def validate_saved_tokens(record:)
              %i[access_token refresh_token].each do |field|
                value = record[field]
                storage_error! unless value.is_a?(String) && value.bytesize.between?(1, 65_536) &&
                                      value.match?(/\A[!-~]+\z/)
              end
            end

            def validate_saved_expiry(expires:)
              storage_error! unless expires.is_a?(Numeric) && expires.finite? && expires.positive?
            end

            def safe_identity?(value:)
              value.is_a?(String) && value.bytesize.between?(1, 512) && value.match?(/\A[\w.:-]+\z/)
            end

            def write_record(instance:, record:)
              prepare_directory(create: false) || storage_error!
              validate_record(record: record, instance: instance)
              key = instance_key(instance: instance)
              target = File.join(@root, "#{key}.json")
              # Validate an existing destination rather than silently repairing an unsafe file.
              read_record(instance: instance)
              temporary = File.join(@root, ".#{key}.#{SecureRandom.hex(16)}.tmp")
              begin
                write_temporary(path: temporary, record: record)
                File.rename(temporary, target)
                File.open(@root, File::RDONLY | File::NOFOLLOW, &:fsync)
              ensure
                FileUtils.rm_f(temporary)
              end
            end

            def write_temporary(path:, record:)
              File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
                validate_file(file: file, path: path)
                file.write(Legion::JSON.dump(record))
                file.flush
                file.fsync
              end
            end

            def storage_error!
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT credential storage is unsafe or unavailable; ' \
                         'use an owned 0700 directory and 0600 unlinked files',
                kind: :provider_error, metadata: { operation: 'credential_storage' }
              ), cause: nil
            end
          end
        end
      end
    end
  end
end
