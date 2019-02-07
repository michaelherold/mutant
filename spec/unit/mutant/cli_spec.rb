# frozen_string_literal: true

RSpec.describe Mutant::CLI do
  let(:default_config) { Mutant::Config::DEFAULT                        }
  let(:kernel)         { instance_double('kernel', exit: undefined)     }
  let(:stderr)         { instance_double(IO, 'stderr', puts: undefined) }
  let(:stdout)         { instance_double(IO, 'stdout', puts: undefined) }
  let(:target_stream)  { stdout                                         }
  let(:undefined)      { instance_double('undefined')                   }

  let(:config) do
    default_config.with(
      fail_fast: false,
      includes:  [],
      requires:  []
    )
  end

  let(:world) do
    instance_double(
      Mutant::World,
      kernel: kernel,
      stderr: stderr,
      stdout: stdout
    )
  end

  shared_examples 'prints expected message' do

    it 'prints expected message' do
      apply

      expect(target_stream).to have_received(:puts).with(expected_message)
    end
  end

  before do
    allow(stderr).to receive_messages(puts: undefined)
    allow(stdout).to receive_messages(puts: undefined)
  end

  describe '.run' do
    def apply
      described_class.run(world, config, arguments)
    end

    let(:arguments)      { instance_double(Array)                           }
    let(:env)            { instance_double(Mutant::Env)                     }
    let(:report_success) { true                                             }
    let(:cli_result)     { Mutant::Either::Right.new(new_config)            }
    let(:new_config)     { instance_double(Mutant::Config, 'parsed config') }

    let(:report) do
      instance_double(Mutant::Result::Env, success?: report_success)
    end

    before do
      allow(Mutant::CLI).to receive_messages(apply: cli_result)
      allow(Mutant::Env::Bootstrap).to receive_messages(call: env)
      allow(Mutant::Runner).to receive_messages(call: report)
    end

    it 'performs calls in expected sequence' do
      apply

      expect(Mutant::CLI)
        .to have_received(:apply)
        .with(world, config, arguments)
        .ordered

      expect(Mutant::Env::Bootstrap)
        .to have_received(:call)
        .with(world, new_config)
        .ordered

      expect(Mutant::Runner)
        .to have_received(:call)
        .with(env)
        .ordered
    end

    context 'when report signals success' do
      let(:report_success) { true }

      it 'exits failure' do
        expect(apply).to be(true)
      end
    end

    context 'when report signals error' do
      let(:report_success) { false }

      it 'exits failure' do
        expect(apply).to be(false)
      end
    end

    context 'when parts of the chain fail' do
      let(:cli_result)       { Mutant::Either::Left.new(expected_message) }
      let(:expected_message) { 'cli-error'                                }
      let(:target_stream)    { stderr                                     }

      include_examples 'prints expected message'

      it 'exits failure' do
        expect(apply).to be(false)
      end
    end
  end

  describe '.apply' do
    def apply
      described_class.apply(world, config, arguments)
    end

    shared_examples 'invalid arguments' do
      it 'returns left error' do
        expect(apply).to eql(Mutant::Either::Left.new(expected_message))
      end
    end

    shared_examples 'explicit exit' do
      it 'prints explicitly exits' do
        apply

        expect(kernel).to have_received(:exit)
      end
    end

    shared_examples 'no explicit exit' do
      it 'does not exit' do
        expect(kernel).to_not have_received(:exit)
      end
    end

    shared_examples_for 'cli parser' do
      it { expect(apply.from_right.integration).to eql(expected_integration) }
      it { expect(apply.from_right.matcher).to eql(expected_matcher_config)  }
    end

    before do
      allow(kernel).to receive_messages(exit: nil)
    end

    let(:arguments)               { (options + expressions).freeze }
    let(:expected_integration)    { Mutant::Integration::Null      }
    let(:expected_matcher_config) { default_matcher_config         }
    let(:expressions)             { %w[TestApp*]                   }
    let(:options)                 { []                             }

    let(:default_matcher_config) do
      Mutant::Matcher::Config::DEFAULT
        .with(match_expressions: expressions.map(&method(:parse_expression)))
    end

    context 'with --invalid option' do
      let(:options)          { %w[--invalid]               }
      let(:expected_message) { 'invalid option: --invalid' }

      include_examples 'invalid arguments'
      include_examples 'no explicit exit'
    end

    context 'with --help option' do
      let(:options) { %w[--help] }

      let(:expected_message) do
        <<~MESSAGE
          usage: mutant [options] MATCH_EXPRESSION ...
          Environment:
                  --zombie                     Run mutant zombified
              -I, --include DIRECTORY          Add DIRECTORY to $LOAD_PATH
              -r, --require NAME               Require file with NAME
              -j, --jobs NUMBER                Number of kill jobs. Defaults to number of processors.

          Options:
                  --use INTEGRATION            Use INTEGRATION to kill mutations
                  --ignore-subject EXPRESSION  Ignore subjects that match EXPRESSION as prefix
                  --since REVISION             Only select subjects touched since REVISION
                  --fail-fast                  Fail fast
                  --version                    Print mutants version
              -h, --help                       Show this message
        MESSAGE
      end

      include_examples 'cli parser'
      include_examples 'explicit exit'
      include_examples 'prints expected message'
    end

    context 'with --include option' do
      let(:options) { %w[--include foo] }

      include_examples 'cli parser'
      include_examples 'no explicit exit'

      it 'configures includes' do
        expect(apply.from_right.includes).to eql(%w[foo])
      end
    end

    context 'with --use option' do
      context 'when integration exists' do
        let(:expected_integration) { integration                          }
        let(:options)              { %w[--use rspec]                      }
        let(:integration)          { instance_double(Mutant::Integration) }

        before do
          allow(Mutant::Integration).to receive_messages(setup: integration)
        end

        include_examples 'cli parser'
        include_examples 'no explicit exit'

        it 'does integration setup' do
          apply

          expect(Mutant::Integration).to have_received(:setup) do |kernel_arg, name|
            expect(kernel_arg).to be(kernel)
            expect(name).to eql('rspec')
          end
        end
      end

      context 'when integration does NOT exist' do
        let(:options) { %w[--use other] }

        let(:expected_message) do
          'invalid argument: '                                    \
          '--use Could not load integration "other" '             \
          '(you may want to try installing the gem mutant-other)'
        end

        before do
          allow(Mutant::Integration).to receive(:setup).and_raise(LoadError)
        end

        it 'returns error' do
          expect(apply).to eql(Mutant::Either::Left.new(expected_message))
        end
      end
    end

    context 'with --version option' do
      let(:expected_message) { "mutant-#{Mutant::VERSION}" }
      let(:options)          { %w[--version]               }

      include_examples 'cli parser'
      include_examples 'explicit exit'
      include_examples 'prints expected message'
    end

    context 'with --jobs option' do
      let(:options) { %w[--jobs 0] }

      include_examples 'cli parser'
      include_examples 'no explicit exit'

      it 'configures expected coverage' do
        expect(apply.from_right.jobs).to eql(0)
      end
    end

    context 'with --require options' do
      let(:options) { %w[--require foo --require bar] }

      include_examples 'cli parser'
      include_examples 'no explicit exit'

      it 'configures requires' do
        expect(apply.from_right.requires).to eql(%w[foo bar])
      end
    end

    context 'with --since option' do
      let(:options) { %w[--since master] }

      let(:expected_matcher_config) do
        default_matcher_config.with(
          subject_filters: [
            Mutant::Repository::SubjectFilter.new(
              Mutant::Repository::Diff.new(
                from:  'HEAD',
                to:    'master',
                world: world
              )
            )
          ]
        )
      end

      include_examples 'cli parser'
      include_examples 'no explicit exit'
    end

    context 'with --subject-ignore option' do
      let(:options) { %w[--ignore-subject Foo::Bar] }

      let(:expected_matcher_config) do
        default_matcher_config.with(ignore_expressions: [parse_expression('Foo::Bar')])
      end

      include_examples 'cli parser'
      include_examples 'no explicit exit'
    end

    context 'with --fail-fast option' do
      let(:options) { %w[--fail-fast] }

      include_examples 'cli parser'
      include_examples 'no explicit exit'

      it 'sets the fail fast option' do
        expect(apply.from_right.fail_fast).to be(true)
      end
    end

    context 'with --zombie option' do
      let(:options) { %w[--zombie] }

      include_examples 'cli parser'
      include_examples 'no explicit exit'

      it 'sets the zombie option' do
        expect(apply.from_right.zombie).to be(true)
      end
    end
  end
end
