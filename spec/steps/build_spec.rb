require 'spec_helper'
require 'tmpdir'
require 'pathname'
require 'fileutils'

require 'mamiya/package'

require 'mamiya/steps/build'

describe Mamiya::Steps::Build do
  let!(:tmpdir) { Dir.mktmpdir("mamiya-steps-build-spec") }
  after { FileUtils.remove_entry_secure tmpdir }

  let(:build_dir)   { Pathname.new(tmpdir).join('build') }
  let(:package_dir) { Pathname.new(tmpdir).join('pkg') }
  let(:extract_dir) { Pathname.new(tmpdir).join('extract') }
  let(:script_dir)  { Pathname.new(tmpdir).join('script').tap(&:mkdir) }

  let(:script_file)  { script_dir.join('deploy.rb').tap { |_| File.write _, "p :script\n" } }

  let(:exclude_from_package) { [] }
  let(:package_under) { nil }
  let(:dereference_symlinks) { false }
  let(:skip_prepare_build) { false }

  let(:package_name) { nil }
  let(:script) do
    double('script',
      application: 'app',
      build_from: build_dir,
      build_to: package_dir,
      before_build: proc {},
      prepare_build: proc {},
      build: proc {},
      after_build: proc {},
      package_name: proc { |_| package_name || _ },
      package_meta: proc { |_| _ },
      package_under: package_under,
      dereference_symlinks: dereference_symlinks,
      exclude_from_package: exclude_from_package,
      skip_prepare_build: skip_prepare_build,
      script_file: script_file,
      script_additionals: [],
      _file: nil,
    )
  end
  
  subject(:build_step) { described_class.new(script: script) }

  describe "#run!" do
    before do
      Dir.mkdir(build_dir)
      Dir.mkdir(package_dir)
      Dir.mkdir(extract_dir)

      File.write(build_dir.join('greeting'), 'hello')
    end

    it "calls hooks with proper order" do
      hooks = %i(before_build prepare_build build after_build)

      flags = []
      hooks.each do |sym|
        allow(script).to receive(sym).and_return(proc { flags << sym })
      end

      expect { build_step.run! }.
        to change { flags }.
        from([]).
        to(hooks)
    end

    it "calls after_build hook even if exception occured" do
      e = Exception.new("Good bye, the cruel world")
      allow(script).to receive(:build).and_return(proc { raise e })

      received = nil
      allow(script).to receive(:after_build).and_return(proc { |_| received = _ })

      expect {
        begin
          build_step.run!
        rescue Exception; end
      }.
        to change { received }.
        from(nil).to(e)
    end

    it "calls build hook in :build_from (pwd)" do
      pwd = nil
      script.stub(build: proc { pwd = Dir.pwd })

      expect {
        build_step.run!
      }.not_to change { Dir.pwd }

      expect(File.realpath(pwd)).to eq script.build_from.realpath.to_s
    end

    it "creates package using Package after :build called" do
      built = false
      allow(script).to receive(:build).and_return(proc { built = true })
      allow(script).to receive(:exclude_from_package).and_return(['test'])
      allow(script).to receive(:dereference_symlinks).and_return(true)
      allow(script).to receive(:package_under).and_return('foo')
      build_dir.join('foo').mkdir

      expect_any_instance_of(Mamiya::Package).to \
        receive(:build!).with(
            build_dir,
            hash_including(
              exclude_from_package: ['test'],
              dereference_symlinks: true,
              package_under: 'foo',
            )
          ) {
        expect(built).to be true
      }

      build_step.run!
    end

    it "creates package with metadata including application" do
      meta = {}
      allow_any_instance_of(Mamiya::Package).to receive(:meta).and_return(meta)
      expect_any_instance_of(Mamiya::Package).to receive(:build!) {
        expect(meta[:application]).to eq 'app'
      }

      build_step.run!
    end

    it "packs script_file into .mamiya.script" do
      expect_any_instance_of(Mamiya::Package).to receive(:build!) do
        expect(build_dir.join('.mamiya.script')).to be_a_directory
        expect(build_dir.join('.mamiya.script', 'deploy.rb').read).to match(/:script/)
      end

      build_step.run!

      expect(build_dir.join('.mamiya.script')).not_to be_exist
    end

    it "writes script_file in meta" do
      meta = {}
      allow_any_instance_of(Mamiya::Package).to receive(:meta).and_return(meta)
      expect_any_instance_of(Mamiya::Package).to receive(:build!) do
        expect(meta[:script]).to eq 'deploy.rb'
      end

      build_step.run!

      expect(build_dir.join('.mamiya.script')).not_to be_exist
    end

    context "when package_under is specified" do
      let(:package_under) { 'hoge' }

      before do
        build_dir.join('hoge').mkdir
        File.write build_dir.join('hoge', 'test'), "hello\n"
      end

      it "places .mamiya.script under :package_under" do
        expect_any_instance_of(Mamiya::Package).to receive(:build!) do
          expect(build_dir.join('hoge', '.mamiya.script')).to be_a_directory
          expect(build_dir.join('hoge', '.mamiya.script', 'deploy.rb').read).to match(/:script/)
        end

        build_step.run!

        expect(build_dir.join('.mamiya.script')).not_to be_exist
      end
    end

    context "with :script_additionals" do
      before do
        allow(script).to receive(:script_additionals).and_return(%w(test))
      end

      it "packs them into .mamiya.script" do
        File.write script_dir.join('test'), "this is test\n"

        expect_any_instance_of(Mamiya::Package).to receive(:build!) do
          expect(build_dir.join('.mamiya.script')).to be_a_directory
          expect(build_dir.join('.mamiya.script', 'deploy.rb').read).to match(/:script/)
          expect(build_dir.join('.mamiya.script', 'test').read).to match(/this is test/)
        end

        build_step.run!

        expect(build_dir.join('.mamiya.script')).not_to be_exist
      end
    end

    context "without script_file and when script is loaded from a file" do
      before do
        allow(script).to receive(:_file).and_return(script_file)
        allow(script).to receive(:script_file).and_return(nil)
      end

      it "assumes loaded file's directory as script_dir and loaded file as script_file" do
        expect_any_instance_of(Mamiya::Package).to receive(:build!) do
          expect(build_dir.join('.mamiya.script')).to be_a_directory
          expect(build_dir.join('.mamiya.script', 'deploy.rb').read).to match(/:script/)
        end

        build_step.run!

        expect(build_dir.join('.mamiya.script')).not_to be_exist
      end
    end

    context "without script_file and when script is not loaded from a file" do
      before do
        allow(script).to receive(:_file).and_return(nil)
        allow(script).to receive(:script_file).and_return(nil)
      end

      it "raises an error" do
        expect {
          build_step.run!
        }.to raise_error Mamiya::Steps::Build::ScriptFileNotSpecified
      end
    end

    context "with package name determiner" do
      it "calls package name determiner with current candidate" do
        received = nil
        allow(script).to receive(:package_name).and_return(proc { |arg| received = arg })

        build_step.run!

        expect(received).to be_a_kind_of(Array)

        # Default candidates
        expect(received.size).to eq 2
        expect(received[0]).to match(/\A\d{14}\z/)
        expect(received[1]).to eq script.application
      end

      it "uses result by joining with '-' as package name to be built" do
        allow(script).to receive(:package_name).and_return(proc { |arg| %w(veni vidi vici) })

        build_step.run!

        expect(package_dir.join('veni-vidi-vici.tar.gz')).to be_exist
      end

      it "calls the determiner in build dir" do
        pwd = nil
        allow(script).to receive(:package_name).and_return(proc { |arg| pwd = Dir.pwd; arg })

        expect {
          build_step.run!
        }.not_to change { Dir.pwd }

        expect(File.realpath(pwd)).to eq script.build_from.realpath.to_s
      end

      context "when the determiner returned non-Array" do
        it "wraps with Array before calling next determiner"
      end
    end

    context "with package meta determiner" do
      it "calls determiners with current candidate" do
        received = nil
        allow(script).to receive(:package_meta).and_return(proc { |arg| received = arg })

        build_step.run!

        expect(received).to be_a_kind_of(Hash)
      end

      it "uses result as package metadata" do
        meta = {}
        allow_any_instance_of(Mamiya::Package).to receive(:meta).and_return(meta)
        allow_any_instance_of(Mamiya::Package).to receive(:build!) { }

        allow(script).to receive(:package_meta).and_return(proc { |arg| {'test' => 'hello'} })

        build_step.run!

        expect(meta['test']).to eq 'hello'
      end

      it "calls the determiner in build dir" do
        pwd = nil
        allow(script).to receive(:package_meta).and_return(proc { |arg| pwd = Dir.pwd; arg })

        expect {
          build_step.run!
        }.not_to change { Dir.pwd }

        expect(File.realpath(pwd)).to eq script.build_from.realpath.to_s
      end
    end

    context "when build_from directory exist" do
      it "calls prepare_build with update=true" do
        arg = nil
        allow(script).to receive(:prepare_build).and_return(proc { |update| arg = update })

        expect {
          build_step.run!
        }.to change { arg }.
          from(nil).to(true)
      end
    end

    context "when build_from directory doesn't exist" do
      before do
        FileUtils.remove_entry_secure(build_dir)
      end

      it "calls prepare_build with update=false" do
        arg = nil
        allow(script).to receive(:prepare_build).and_return(proc { |update| arg = update })

        expect {
          begin
            build_step.run!
          rescue Errno::ENOENT; end
        }.to change { arg }.
          from(nil).to(false)
      end

      it "raises error" do
        expect {
          build_step.run!
        }.to raise_error(Errno::ENOENT)
      end
    end


    context "with skip_prepare_build option" do
      context "when the option is false" do
        let(:skip_prepare_build) { false }

        it "calls prepare_build" do
          flag = false
          allow(script).to receive(:prepare_build).and_return(proc { flag = true })

          expect { build_step.run! }.to change { flag }.
            from(false).to(true)
        end
      end

      context "when the option is true" do
        let(:skip_prepare_build) { true }

        it "doesn't call prepare_build" do
          flag = false
          allow(script).to receive(:prepare_build).and_return(proc { flag = true })

          expect { build_step.run! }.not_to change { flag }
        end
      end
    end
  end
end
