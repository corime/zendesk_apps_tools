require 'spec_helper'
require 'command'
require 'server'
require 'faraday'
require 'zip'

describe ZendeskAppsTools::Command do
  PREFIX = 'https://subdomain.zendesk.com'
  AUTHORIZATION_HEADER = { 'Authorization' => 'Basic dXNlcm5hbWVAc29tZXRoaW5nLmNvbTpwYXNzd29yZA==' }

  before do
    @command = ZendeskAppsTools::Command.new
    @command.instance_variable_set(:@username, 'username@something.com')
    @command.instance_variable_set(:@password, 'password')
    @command.instance_variable_set(:@subdomain, 'subdomain')
    @command.instance_variable_set(:@app_id, '123')

    allow(@command.cache).to receive(:fetch)
    allow(@command.cache).to receive(:save)
    allow(@command.cache).to receive(:clear)
    allow(@command).to receive(:options) { { clean: false, path: './' } }
    allow(@command).to receive(:product_names).and_return(['support'])
  end

  describe '#upload' do
    context 'when no zipfile is given' do
      it 'uploads the newly packaged zipfile and returns an upload id' do
        expect(@command).to receive(:package)
        allow(@command).to receive(:options) { { zipfile: nil } }
        allow(Faraday::UploadIO).to receive(:new)

        stub_request(:post, PREFIX + '/api/v2/apps/uploads.json')
          .with(headers: AUTHORIZATION_HEADER)
          .to_return(body: '{ "id": 123 }')

        expect(@command.upload('nah')).to eq(123)
      end
    end

    context 'when zipfile is given' do
      it 'uploads the given zipfile and returns an upload id' do
        allow(@command).to receive(:options) { { zipfile: 'app.zip' } }
        expect(Faraday::UploadIO).to receive(:new).with('app.zip', 'application/zip').and_return(nil)

        stub_request(:post, PREFIX + '/api/v2/apps/uploads.json')
          .with(headers: AUTHORIZATION_HEADER)
          .to_return(body: '{ "id": 123 }')

        expect(@command.upload('nah')).to eq(123)
      end
    end
  end

  describe '#create' do
    context 'when no zipfile is given' do
      it 'uploads a file and posts build api' do
        expect(@command).to receive(:upload).and_return(123)
        allow(@command).to receive(:check_status)
        expect(@command).to receive(:manifest).and_return(double('manifest', name: 'abc', original_parameters: [])).at_least(:once)
        allow(@command).to receive(:options).and_return(clean: false, path: './', config: './settings.json', install: true)
        allow(@command.cache).to receive(:fetch).with('app_id').and_return('987')

        stub_request(:post, PREFIX + '/api/apps.json')
          .with(
            body: JSON.generate(name: 'abc', upload_id: '123'),
            headers: AUTHORIZATION_HEADER
          )

        stub_request(:post, PREFIX + '/api/support/apps/installations.json')
          .with(
            body: JSON.generate(app_id: '987', settings: { name: 'abc' }),
            headers: AUTHORIZATION_HEADER.merge({ 'Content-Type' => 'application/json' })
          )

        @command.create
      end
    end

    context 'when zipfile is given' do
      it 'uploads the zipfile and posts build api' do
        expect(@command).to receive(:upload).and_return(123)
        allow(@command).to receive(:check_status)
        allow(@command).to receive(:options).and_return(clean: false, path: './', zipfile: 'abc.zip', config: './settings.json', install: true)
        expect(@command).to receive(:manifest).and_return(double('manifest', name: 'abc', original_parameters: [])).at_least(:once)

        expect(@command).to receive(:get_value_from_stdin) { 'abc' }

        stub_request(:post, PREFIX + '/api/apps.json')
          .with(
            body: JSON.generate(name: 'abc', upload_id: '123'),
            headers: AUTHORIZATION_HEADER
          )

        stub_request(:post, PREFIX + '/api/support/apps/installations.json')
          .with(
            body: JSON.generate(app_id: nil, settings: { name: 'abc' }),
            headers: AUTHORIZATION_HEADER.merge({ 'Content-Type' => 'application/json' })
          )

        @command.create
      end
    end
  end

  describe '#update' do
    context 'when app id is in cache' do
      it 'uploads a file and puts build api' do
        expect(@command).to receive(:upload).and_return(123)
        allow(@command).to receive(:check_status)
        expect(@command.cache).to receive(:fetch).with('app_id').and_return(456)

        stub_request(:put, PREFIX + '/api/v2/apps/456.json')
          .with(headers: AUTHORIZATION_HEADER)
        stub_request(:get, PREFIX + '/api/v2/apps/456.json')
          .with(headers: AUTHORIZATION_HEADER)
          .to_return(:status => 200)

        @command.update
      end

      context 'when app id is in cache and is invalid' do
        it 'displays error message and exits' do
          stub_request(:get, PREFIX + '/api/v2/apps/333.json')
            .with(headers: AUTHORIZATION_HEADER)
            .to_return(:status => 404)

          expect(@command.cache).to receive(:fetch).with('app_id').and_return(333)
          expect(@command).to receive(:say_error).with(/^App id not found/)
          expect(@command).to_not receive(:deploy_app)

          expect { @command.update }.to raise_error(SystemExit)
        end
      end
    end

    context 'when app id is not in cache' do
      let (:apps) {
        {
          apps: [
            { name: 'hello', id: 123 },
            { name: 'world', id: 124 },
            { name: 'itsme', id: 125 }
          ]
        }
      }

      before do
        @command.instance_variable_set(:@app_id, nil)
        allow(@command).to receive(:get_value_from_stdin).and_return('itsme')
      end

      it 'cannot find the app id' do
        stub_request(:get, PREFIX + '/api/apps.json')
          .with(headers: AUTHORIZATION_HEADER)
          .to_return(body: '')
        expect(@command).to receive(:say_error).with(
          "App not found. " \
          "Please verify that your credentials, subdomain, and app name are correct."
        )
        expect { @command.update }.to raise_error(SystemExit)
      end

      it 'finds the app id' do
        stub_request(:get, PREFIX + '/api/apps.json')
          .with(headers: AUTHORIZATION_HEADER)
          .to_return(body: JSON.generate(apps))
        stub_request(:get, PREFIX + '/api/v2/apps/125.json')
          .with(headers: AUTHORIZATION_HEADER)
          .to_return(:status => 200)

        expect(@command.send(:find_app_id)).to eq(125)

        allow(@command).to receive(:deploy_app)
        @command.update
      end
    end
  end

  describe '#version' do
    context 'when -v is run' do
      it 'shows the version' do
        old_v = Gem::Version.new '0.0.1'
        new_v = nil

        expect(@command).to receive(:say) { |arg| new_v = Gem::Version.new arg }
        @command.version

        expect(old_v).to be < new_v
      end
    end
  end

  describe '#check_for_update' do
    context 'more than one week since the last check' do
      it 'checks for updates' do
        allow(@command.cache).to receive(:fetch).with('zat_update_check').and_return('1970-01-01')

        stub_request(:get, "https://rubygems.org/api/v1/gems/zendesk_apps_tools.json")
          .to_return(:body => JSON.dump(version: ZendeskAppsTools::VERSION))

        expect(@command).to receive(:say_status).with('info', 'Checking for new version of zendesk_apps_tools')
        @command.send(:check_for_update)
      end

      context 'the version is outdated' do
        it 'display message to update' do
          new_v = Gem::Version.new(ZendeskAppsTools::VERSION).bump

          allow(@command.cache).to receive(:fetch).with('zat_update_check').and_return('1970-01-01')

          stub_request(:get, "https://rubygems.org/api/v1/gems/zendesk_apps_tools.json")
            .to_return(:body => JSON.dump(version: new_v.to_s))

          expect(@command).to receive(:say_status).with('info', 'Checking for new version of zendesk_apps_tools')
          expect(@command).to receive(:say_status).with('warning', 'Your version of Zendesk Apps Tools is outdated. Update by running: gem update zendesk_apps_tools', :yellow)
          @command.send(:check_for_update)
        end
      end
    end

    context 'less than one week since the last check' do
      it 'does not check for updates' do
        allow(@command.cache).to receive(:fetch).with('zat_update_check').and_return(Date.today.to_s)

        expect(@command).not_to receive(:say_status).with('info', 'Checking for new version of zendesk_apps_tools')
        @command.send(:check_for_update)
      end
    end
  end

  describe '#server' do
    it 'runs the server' do
      path = './tmp/tmp_app'
      allow(@command).to receive(:options) { { path: path } }
      expect(ZendeskAppsTools::Server).to receive(:run!)
      @command.directory('app_template_iframe', path, {})
      @command.server
    end
  end

  describe '#new' do
    context 'when --scaffold option is given' do
      it 'creates a base project with scaffold' do
        allow(@command).to receive(:options) { { scaffold: true } }
        allow(@command).to receive(:get_value_from_stdin) { 'TestApp' }

        expect(@command).to receive(:directory).with('app_template_iframe', 'TestApp', {:exclude_pattern=>/^((?!manifest.json).)*$/})

        stub_request(:get, 'https://github.com/zendesk/app_scaffold/archive/master.zip')
          .to_return(body: 'Mock Zip Body', status: 200)

        mockFile = Zip::Entry.new('', 'mockfile.json')
        allow(Zip::File).to receive(:open) {[mockFile]}

        expect(FileUtils).to receive(:mv)
        expect(mockFile).to receive(:extract).with('TestApp/mockfile.json')

        @command.new

      end
    end
  end
end
