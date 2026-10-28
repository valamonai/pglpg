# frozen_string_literal: true

RSpec.describe "visibility leak suite" do
  [1, 2, 3].each do |clearance|
    context "with clearance #{clearance}" do
      it_behaves_like "a pglpg visibility policy" do
        let(:pglpg_visibility) { ClearancePolicy }
        let(:pglpg_viewer) { Viewer.new(clearance) }
        let(:pglpg_columns) { { classification: [:integer, { null: false }] } }
        let(:pglpg_visible_attrs) { { classification: clearance } }
        let(:pglpg_hidden_attrs) { { classification: clearance + 1 } }
      end
    end
  end

  # A policy that filters nodes but forgets edges must be caught.
  context "with a policy that ignores edge visibility" do
    leaky = Module.new do
      def self.node(table, viewer) = table[:classification].lteq(viewer.clearance)
      def self.edge(_table, _viewer) = Arel.sql("TRUE")
    end

    it "fails the suite" do
      group = RSpec.describe("leaky") do
        it_behaves_like "a pglpg visibility policy" do
          let(:pglpg_visibility) { leaky }
          let(:pglpg_viewer) { Viewer.new(1) }
          let(:pglpg_columns) { { classification: [:integer, { null: false }] } }
          let(:pglpg_visible_attrs) { { classification: 1 } }
          let(:pglpg_hidden_attrs) { { classification: 2 } }
        end
      end
      expect(group.run(RSpec::Core::NullReporter)).to be(false)
      errors = group.descendants.flat_map(&:examples).map { _1.execution_result.exception&.message }
      expect(errors.compact.join).to match(/observation \w+ changed|is visible/)
    end
  end
end
