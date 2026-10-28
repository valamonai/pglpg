# frozen_string_literal: true

RSpec.describe "concurrent writes", :committed do
  THREADS = 8

  def concurrently
    barrier = Queue.new
    threads = Array.new(THREADS) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          ActiveRecord::Base.transaction { yield i }
        end
      end
    end
    THREADS.times { barrier << true }
    threads.map(&:value)
  end

  it "upserts of the same node key produce one row and the same Ref" do
    refs = concurrently do |i|
      trusted.upsert_node(:Person, key: { uid: "PER-RACE" }, properties: { rank: i }, attrs: { classification: 1 })
    end
    expect(refs.uniq.size).to eq(1)
    expect(ctx.match.node(:p, :Person).count).to eq(1)
  end

  it "upserts of the same subtype key produce one row" do
    refs = concurrently do
      trusted.upsert_node(:Employee, key: { uid: "EMP-RACE" }, attrs: { classification: 1 })
    end
    expect(refs.uniq.size).to eq(1)
  end

  it "upserts of the same unique pair produce one edge and the same Ref" do
    a = person(1)
    j = project(1)
    refs = concurrently do |i|
      trusted.upsert_edge(:WORKS_ON, from: a, to: j, properties: { role: "r#{i}" }, attrs: { classification: 1 })
    end
    expect(refs.uniq.size).to eq(1)
    expect(ctx.match.node(:p, ref: a).out(:WORKS_ON, :j).count).to eq(1)
  end

  it "keeps an edge's endpoints locked until commit" do
    a = person(1)
    b = person(1)
    inserted = Queue.new
    release = Queue.new
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          ctx(1).insert_edge(:KNOWS, from: a, to: b, attrs: { classification: 1 })
          inserted << true
          release.pop
        end
      end
    end
    inserted.pop
    blocked = ActiveRecord::Base.connection_pool.with_connection do |c|
      c.transaction do
        c.execute("SET LOCAL lock_timeout = '100ms'")
        c.execute("UPDATE #{Kg.nodes_table} SET classification = 4 WHERE id = #{b.id}")
        false
      end
    rescue ActiveRecord::LockWaitTimeout
      true
    end
    release << true
    writer.join
    expect(blocked).to be(true)
  end
end
