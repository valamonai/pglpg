# frozen_string_literal: true

module Pglpg
  # Helpers for the shared leak specs (see testing/leak_examples.rb).
  module Testing
    # Sees everything; used only to seed fixtures.
    module SeeAll
      def self.node(_table, _viewer) = Arel.sql("TRUE")

      def self.edge(_table, _viewer) = Arel.sql("TRUE")
    end

    # Allows every write; used only to seed fixtures.
    module AllowAll
      def self.authorize?(_request) = true
    end

    module_function

    # Everything the viewer can observe through the query API on the leak
    # graph, as plain data.
    def observe(ctx, refs)
      m = -> { ctx.match }
      queries = {
        persons: -> { m.().node(:p, :Person).order(p: :name) },
        works_on: -> { m.().node(:p, :Person).out(:WORKS_ON, :j, :Project, edge: :w) },
        two_hops: -> { m.().node(:p, :Person).out(:WORKS_ON, :j, :Project).out(:BASED_AT, :l, :Location) },
        knows_chain: -> { m.().node(:a, :Person).out(:KNOWS, :b, :Person).out(:KNOWS, :c, :Person) },
        inbound: -> { m.().node(:l, :Location).in(:BASED_AT, :j, :Project).in(:WORKS_ON, :p, :Person) },
        branch: -> { m.().node(:j, :Project).in(:WORKS_ON, :p, :Person).out(:BASED_AT, :l, :Location, from: :j) },
        unlabeled: -> { m.().node(:x).out(:KNOWS, :y) },
        leads: -> { m.().node(:p, :Person).out(:WORKS_ON, :j, :Project, edge: :w).where(w: { role: "lead" }) },
        ranked: -> { m.().node(:p, :Person).where(p: { rank: Pglpg.gte(2) }) },
        by_title: -> { m.().node(:j, :Project, title: "Apollo").in(:WORKS_ON, :p, :Person) },
        projects: -> { m.().node(:p, :Person).out(:WORKS_ON, :j, :Project).return(:j).distinct },
        page: -> { m.().node(:p, :Person).out(:WORKS_ON, :j, :Project).limit(2).offset(1) },
        ann: -> { m.().node(:p, :Person, name: "Ann").out(:WORKS_ON, :j, :Project) },
        cid_knows: -> { m.().node(:p, :Person, name: "Cid").out(:KNOWS, :q) },
        friends: -> { m.().node(:p, :Person).both(:FRIEND, :q, :Person, edge: :f) },
        friend_edges: -> { m.().node(:p, :Person).both(:FRIEND, :q, edge: :f).return(:f).distinct },
        friend_chain: -> { m.().node(:a, :Person).both(:FRIEND, :b).both(:FRIEND, :c) },
        ann_friends: -> { m.().node(:p, :Person, name: "Ann").both(:FRIEND, :q) },
        friends_page: -> { m.().node(:p, :Person).both(:FRIEND, :q).limit(2).offset(1) }
      }
      out = {}
      queries.each do |name, q|
        out[name] = q.().to_a.map { |row| row.transform_values { element_data(_1) } }
        out[:"#{name}_count"] = q.().count
        out[:"#{name}_exists"] = q.().exists?
        out[:"#{name}_first"] = q.().first&.transform_values { element_data(_1) }
      end
      reach = {
        knows: { via: %i[KNOWS] },
        knows_in: { via: %i[KNOWS], direction: :in },
        friends: { via: %i[FRIEND], direction: :both },
        works: { via: %i[WORKS_ON BASED_AT] },
        works_in: { via: %i[WORKS_ON BASED_AT], direction: :in },
        knows_capped: { via: %i[KNOWS], max_nodes: 1 },
        friends_capped: { via: %i[FRIEND], direction: :both, max_nodes: 1 }
      }
      # Within the application's row cap, which may be smaller than 10.
      budget = [10, Pglpg.configuration.max_rows].min
      reach.each do |name, args|
        out[:"reach_#{name}"] = refs.select(&:node?).map do |ref|
          r = ctx.reachable(from: ref, max_depth: 3, max_nodes: budget, **args)
          [r.nodes.map { |node, depth| [node.id, depth] }, r.complete, r.stopped_at_depth]
        end
      end
      out[:last_by_name] = element_data(m.().node(:p, :Person).order(p: { name: :desc }).first&.fetch(:p))
      out[:find] = refs.map { element_data(ctx.find(_1)) }
      out[:find_node] = %w[P1 P2 P3 H1].map { element_data(ctx.find_node(:Person, uid: _1)) }
      out.merge(observe_models(ctx, refs))
    end

    # The same observations through the model layer (ADR-0010).
    def observe_models(ctx, refs)
      models = leak_models(ctx.graph)
      relations = {
        persons: -> { models[:Person].in(ctx).order(:name) },
        ranked: -> { models[:Person].in(ctx).where(rank: Pglpg.gte(2)).order(rank: :desc) },
        persons_page: -> { models[:Person].in(ctx).order(:name).limit(2).offset(1) },
        projects: -> { models[:Project].in(ctx) },
        works_on: -> { models[:WORKS_ON].in(ctx).order(:role) },
        leads: -> { models[:WORKS_ON].in(ctx).where(role: "lead") },
        knows: -> { models[:KNOWS].in(ctx) },
        friends: -> { models[:FRIEND].in(ctx) },
        friends_page: -> { models[:FRIEND].in(ctx).limit(1).offset(1) }
      }
      out = {}
      relations.each do |name, r|
        out[:"model_#{name}"] = r.().map { model_data(_1) }
        out[:"model_#{name}_count"] = r.().count
        out[:"model_#{name}_exists"] = r.().exists?
        out[:"model_#{name}_first"] = model_data(r.().first)
      end
      out[:model_find_by] = %w[P1 P2 P3 H1].map { model_data(models[:Person].in(ctx).find_by(uid: _1)) }
      out[:model_find] = refs.map do |ref|
        model = ref.node? ? models[:Person] : models[:WORKS_ON]
        model_data(model.in(ctx).find(ref))
      rescue Pglpg::Model::RecordNotFound
        nil
      end
      out.merge(observe_associations(ctx, models))
    end

    # Association target and binding queries from every visible owner.
    def observe_associations(ctx, models)
      pair = ->((node, edge)) { [model_data(node), model_data(edge)] }
      owners = models[:Person].in(ctx).order(:uid).to_a + models[:Project].in(ctx).order(:uid).to_a
      owners.to_h do |owner|
        data = owner.class.associations.keys.to_h do |name|
          targets = -> { owner.public_send(name) }
          [name, {
            rows: targets.().map { model_data(_1) },
            count: targets.().count,
            exists: targets.().exists?,
            first: model_data(targets.().first),
            page: targets.().limit(1).offset(1).map { model_data(_1) },
            pairs: targets.().with_rel.map(&pair),
            pairs_count: targets.().with_rel.count,
            pairs_page: targets.().with_rel.limit(1).offset(1).map(&pair)
          }]
        end
        data[:leads] = owner.projects.rel_where(role: "lead").map { model_data(_1) } if owner.respond_to?(:projects)
        [:"assoc_#{owner.uid}", data]
      end
    end

    def model_data(record)
      return nil if record.nil?

      data = [record.class.schema_type.name, record.id, record.attributes, record.extra_properties]
      data + (record.is_a?(Pglpg::Model::Edge) ? [record.source.id, record.target.id] : [record.labels])
    end

    # One model per type of the leak graph, built once per graph.
    def leak_models(leak_graph)
      (@leak_models ||= ObjectSpace::WeakKeyMap.new)[leak_graph] ||=
        %i[Person Project WORKS_ON KNOWS FRIEND].to_h do |type|
          base = leak_graph.type.node_types.key?(type) ? Pglpg::Model::Node : Pglpg::Model::Edge
          [type, Class.new(base) { graph(leak_graph, type:) }]
        end.tap do |models|
          models[:Person].has_many :projects, :out, edge: :WORKS_ON
          models[:Person].has_many :known, :out, edge: :KNOWS
          models[:Person].has_many :known_by, :in, edge: :KNOWS
          models[:Person].has_many :friends, :both, edge: :FRIEND
          models[:Project].has_many :people, :in, edge: :WORKS_ON
        end
    end

    def element_data(element)
      case element
      when nil then nil
      when Pglpg::Node then [:node, element.id, element.key_label, element.labels, element.properties, element.attrs]
      when Pglpg::Edge
        [:edge, element.id, element.type, element.source.id, element.target.id, element.properties, element.attrs]
      end
    end
  end
end

require_relative "model"
require_relative "testing/leak_examples" if defined?(RSpec)
