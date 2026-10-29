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
      out[:last_by_name] = element_data(m.().node(:p, :Person).order(p: { name: :desc }).first&.fetch(:p))
      out[:find] = refs.map { element_data(ctx.find(_1)) }
      out[:find_node] = %w[P1 P2 P3 H1].map { element_data(ctx.find_node(:Person, uid: _1)) }
      out
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

require_relative "testing/leak_examples" if defined?(RSpec)
