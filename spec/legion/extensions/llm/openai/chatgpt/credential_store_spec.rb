# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../../support/chatgpt_auth_fixture'

RSpec.describe Legion::Extensions::Llm::Openai::Chatgpt::CredentialStore, :chatgpt_auth do
  let(:chatgpt) { Legion::Extensions::Llm::Openai::Chatgpt }

  def record_path(instance: 'personal', suffix: 'json')
    File.join(credential_root, "#{Base64.urlsafe_encode64(instance, padding: false)}.#{suffix}")
  end

  def fork_result(&)
    reader, writer = IO.pipe
    pid = Process.fork do
      reader.close
      begin
        writer.write(Legion::JSON.dump(yield))
        writer.close
        Process.exit!(0)
      rescue StandardError
        Legion::Logging.error('ChatGPT fixture child failed')
        writer.close
        Process.exit!(1)
      end
    end
    writer.close
    [pid, reader]
  end

  def child_result(child:)
    pid, reader = child
    result = Timeout.timeout(10) { Legion::JSON.load(reader.read) }
    _, status = Process.waitpid2(pid)
    expect(status).to be_success
    result
  ensure
    reader.close
  end

  it 'survives a process restart with read-only status and no credentials in public results' do
    seed_login(store: store, expires_at: 1)
    original = File.binread(record_path)
    child = fork_result do
      restarted = described_class.new(root: credential_root)
      chatgpt::Auth.status(instance: 'personal', store: restarted)
    end
    result = child_result(child: child)
    expect(result).to include(status: 'expired_refreshable', account_id: 'fixture-account', workspace_id: nil)
    expect(result.keys).to contain_exactly(:instance, :auth_mode, :status, :account_id, :workspace_id, :expires_at)
    expect(File.binread(record_path)).to eq(original)
    expect(File.stat(record_path).mode & 0o777).to eq(0o600)
  end

  it 'encodes distinct exact instance names injectively without creating path components' do
    seed_login(store: store, instance: '../personal')
    seed_login(store: store, instance: '.._personal', account: 'fixture-other')
    expect(chatgpt::Auth.instances(store: store)).to include(
      '../personal' => a_hash_including(account_id: 'fixture-account'),
      '.._personal' => a_hash_including(account_id: 'fixture-other')
    )
    expect(store.read(instance: '../personal')[:instance]).to eq('../personal')
    expect(store.read(instance: '.._personal')[:instance]).to eq('.._personal')
  end

  it 'requires exact record identity instead of accepting the filename alone' do
    seed_login(store: store)
    record = store.read(instance: 'personal').merge(instance: 'different-instance')
    File.write(record_path, Legion::JSON.dump(record))
    expect { store.read(instance: 'personal') }.to raise_error(chatgpt::Error)
  end

  it 'does not let an older login replace a later explicit login or logout' do
    first = store.begin_login(instance: 'personal')
    second = store.begin_login(instance: 'personal')
    bundle = { access_token: fixture_token, refresh_token: 'fixture-refresh', expires_at: Time.now.to_f + 3600,
               account_id: 'fixture-account', workspace_id: nil, residency: nil }
    store.complete_login(instance: 'personal', generation: second, bundle: bundle)
    expect do
      store.complete_login(instance: 'personal', generation: first, bundle: bundle)
    end.to raise_error(chatgpt::Error)
    third = store.begin_login(instance: 'personal')
    store.logout(instance: 'personal')
    expect do
      store.complete_login(instance: 'personal', generation: third, bundle: bundle)
    end.to raise_error(chatgpt::Error)
    expect do
      store.complete_login(instance: 'personal', generation: nil, bundle: bundle)
    end.to raise_error(chatgpt::Error)
    expect(chatgpt::Auth.instances(store: store)).to be_empty
    expect(store.read(instance: 'personal')).not_to include(:access_token, :refresh_token)
  end

  it 'allows only one process to rotate an expired bundle and lets the waiter consume its replacement' do
    seed_login(store: store, expires_at: 1)
    rotations = 0
    ready_reader, ready_writer = IO.pipe
    server = with_oauth_server do |_request|
      rotations += 1
      sleep(0.05)
      [200, fixture_response]
    end
    children = Array.new(2) do
      fork_result do
        ready_writer.close
        ready_reader.read(1)
        ready_reader.close
        restarted = described_class.new(root: credential_root)
        chatgpt::Auth.credentials(instance: 'personal', expected_account_id: 'fixture-account',
                                  expected_workspace_id: nil, store: restarted, http: server.http)
      end
    end
    ready_reader.close
    ready_writer.write('go')
    ready_writer.close
    results = children.map { |child| child_result(child: child) }
    expect(rotations).to eq(1)
    expect(results.first).to eq(results.last)
    expect(store.read(instance: 'personal')[:refresh_token]).to eq('fixture-refresh-rotated')
  end

  it 'serializes logout behind an active refresh and never resurrects its credentials afterward' do
    seed_login(store: store, expires_at: 1)
    started = Queue.new
    release = Queue.new
    server = with_oauth_server do |_request|
      started << true
      release.pop
      [200, fixture_response]
    end
    refresher = fork_result do
      chatgpt::Auth.credentials(instance: 'personal', expected_account_id: 'fixture-account',
                                expected_workspace_id: nil, store: described_class.new(root: credential_root),
                                http: server.http)
    end
    Timeout.timeout(5) { started.pop }
    logout = fork_result do
      chatgpt::Auth.logout(instance: 'personal', store: described_class.new(root: credential_root))
    end
    release << true
    expect(child_result(child: refresher)[:refresh_token]).to eq('fixture-refresh-rotated')
    expect(child_result(child: logout)[:status]).to eq('missing')
    expect do
      chatgpt::Auth.credentials(instance: 'personal', expected_account_id: 'fixture-account',
                                expected_workspace_id: nil, store: store)
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:authentication) }
    expect(store.read(instance: 'personal')).not_to include(:access_token, :refresh_token)
  end

  it 'keeps an existing public settings ancestor while securing the default auth subtree' do
    settings = File.join(credential_root, '.legionio')
    Dir.mkdir(settings, 0o755)
    allow(Dir).to receive(:home).and_return(credential_root)
    default_store = described_class.new
    expect(chatgpt::Auth.instances(store: default_store)).to be_empty
    expect(File).not_to exist(File.join(settings, 'auth'))
    seed_login(store: default_store)
    expect(chatgpt::Auth.status(instance: 'personal', store: default_store)[:status]).to eq('authenticated')
    expect(File.stat(settings).mode & 0o777).to eq(0o755)
    expect(File.stat(File.join(settings, 'auth')).mode & 0o777).to eq(0o700)
  end

  it 'rejects a public credential directory rather than silently repairing it' do
    File.chmod(0o755, credential_root)
    expect { store.begin_login(instance: 'personal') }.to raise_error(chatgpt::Error)
  ensure
    File.chmod(0o700, credential_root)
  end

  it 'rejects readable credential records even when their content is valid' do
    seed_login(store: store)
    File.chmod(0o644, record_path)
    expect { store.read(instance: 'personal') }.to raise_error(chatgpt::Error)
    expect { store.logout(instance: 'personal') }.to raise_error(chatgpt::Error)
  end

  it 'rejects symlinked records without reading or replacing their targets' do
    seed_login(store: store)
    target = File.join(credential_root, 'private-target')
    File.rename(record_path, target)
    original = File.binread(target)
    File.symlink(target, record_path)
    expect { store.read(instance: 'personal') }.to raise_error(chatgpt::Error)
    expect { store.logout(instance: 'personal') }.to raise_error(chatgpt::Error)
    expect(File.binread(target)).to eq(original)
  end

  it 'rejects hardlinked stable lock inodes' do
    seed_login(store: store)
    File.link(record_path(suffix: 'lock'), File.join(credential_root, 'lock-alias'))
    expect { store.read(instance: 'personal') }.to raise_error(chatgpt::Error)
    expect { store.logout(instance: 'personal') }.to raise_error(chatgpt::Error)
  end

  it 'rejects symlinked parents and noncanonical explicit roots' do
    target = File.join(credential_root, 'target')
    Dir.mkdir(target, 0o700)
    link = File.join(credential_root, 'link')
    File.symlink(target, link)
    expect do
      described_class.new(root: File.join(link,
                                          'credentials')).begin_login(instance: 'personal')
    end.to raise_error(chatgpt::Error)
    expect { described_class.new(root: File.join(target, '..', 'credentials')) }.to raise_error(chatgpt::Error)
    expect(Dir.children(target)).to be_empty
  end

  it 'rejects hardlinked credentials instead of exposing a second readable copy' do
    seed_login(store: store)
    File.link(record_path, File.join(credential_root, 'record-alias'))
    expect { store.read(instance: 'personal') }.to raise_error(chatgpt::Error)
    expect { store.logout(instance: 'personal') }.to raise_error(chatgpt::Error)
  end
end
