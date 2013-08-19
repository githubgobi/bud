require './test_common'

class SimpleRse
  include Bud

  state do
    table :sbuf, [:id] => [:val]
    scratch :res, sbuf.schema
    table :res_approx, sbuf.schema
  end

  bloom do
    res <= sbuf.notin(res_approx)
  end
end

class SimpleRseQual
  include Bud

  state do
    table :sbuf, [:id] => [:val]
    scratch :res, sbuf.schema
    table :sbuf_val_seen, [:val]
  end

  # This case does not match code generated by RCE, but seems worth supporting
  # anyway
  bloom do
    res <= sbuf.notin(sbuf_val_seen, :val => :val)
  end
end

class JoinRse
  include Bud

  state do
    table :node, [:addr, :epoch]
    table :sbuf, [:id] => [:epoch, :val]
    scratch :res, [:addr] + sbuf.cols
    table :res_approx, res.schema
  end

  bloom do
    res <= ((sbuf * node).pairs(:epoch => :epoch) {|s,n| [n.addr] + s}).notin(res_approx)
  end
end

# RSE for joins with no join predicate -- i.e., cartesian products
class JoinRseNoQual
  include Bud

  state do
    table :node, [:addr]
    table :sbuf, [:id] => [:val]
    scratch :res, sbuf.cols + node.cols # Reverse column order for fun
    table :res_approx, res.schema
  end

  bloom do
    res <= ((sbuf * node).pairs {|s,n| s + n}).notin(res_approx)
  end
end

class TestRse < MiniTest::Unit::TestCase
  def test_simple_rse
    s = SimpleRse.new
    s.sbuf <+ [[5, 10], [6, 12]]
    s.tick
    s.res_approx <+ [[5, 10]]
    s.tick
    s.tick

    assert_equal([[6, 12]], s.sbuf.to_a.sort)
  end

  def test_simple_rse_qual
    s = SimpleRseQual.new
    s.sbuf <+ [[1, 5], [2, 5], [3, 6]]
    s.tick
    assert_equal([[1, 5], [2, 5], [3, 6]].sort, s.res.to_a.sort)

    s.sbuf_val_seen <+ [[5]]
    s.tick
    s.tick

    assert_equal([[3, 6]], s.res.to_a.sort)
    assert_equal([[3, 6]], s.sbuf.to_a.sort)
  end

  def test_join_rse
    j = JoinRse.new
    j.node <+ [["foo", 1], ["bar", 1], ["bar", 2]]
    j.sbuf <+ [[100, 1, "x"], [101, 1, "y"]]
    2.times { j.tick }
    assert_equal([[100, 1, "x"], [101, 1, "y"]], j.sbuf.to_a.sort)
    assert_equal([["bar", 1], ["bar", 2], ["foo", 1]], j.node.to_a.sort)

    j.res_approx <+ [["foo", 100, 1, "x"], ["foo", 101, 1, "y"]]
    2.times { j.tick }
    assert_equal([[100, 1, "x"], [101, 1, "y"]], j.sbuf.to_a.sort)
    assert_equal([["bar", 1], ["bar", 2], ["foo", 1]], j.node.to_a.sort)

    # No more messages in epoch 1
    j.seal_sbuf_epoch <+ [[1]]
    2.times { j.tick }
    assert_equal([[100, 1, "x"], [101, 1, "y"]], j.sbuf.to_a.sort)
    assert_equal([["bar", 1], ["bar", 2]], j.node.to_a.sort)

    # No more node addresses in epoch 1
    j.seal_node_epoch <+ [[1]]
    2.times { j.tick }
    assert_equal([[100, 1, "x"], [101, 1, "y"]], j.sbuf.to_a.sort)
    assert_equal([["bar", 1], ["bar", 2]], j.node.to_a.sort)

    j.res_approx <+ [["bar", 100, 1, "x"]]
    2.times { j.tick }
    assert_equal([[101, 1, "y"]], j.sbuf.to_a.sort)
    assert_equal([["bar", 1], ["bar", 2]], j.node.to_a.sort)

    j.res_approx <+ [["bar", 101, 1, "y"]]
    2.times { j.tick }
    assert_equal([], j.sbuf.to_a.sort)
    assert_equal([["bar", 2]], j.node.to_a.sort)
  end

  def test_join_rse_no_qual
    j = JoinRseNoQual.new
    j.node <+ [["foo"], ["bar"]]
    j.sbuf <+ [[1, "x"], [2, "y"], [3, "z"]]
    2.times { j. tick }
    assert_equal([["bar"], ["foo"]], j.node.to_a.sort)
    assert_equal([[1, "x"], [2, "y"], [3, "z"]], j.sbuf.to_a.sort)

    j.seal_node <+ [["..."]]
    2.times { j. tick }
    assert_equal([["bar"], ["foo"]], j.node.to_a.sort)
    assert_equal([[1, "x"], [2, "y"], [3, "z"]], j.sbuf.to_a.sort)

    j.res_approx <+ [[1, "x", "foo"], [2, "y", "bar"],
                     [3, "z", "foo"], [3, "z", "bar"]]
    2.times { j. tick }
    assert_equal([["bar"], ["foo"]], j.node.to_a.sort)
    assert_equal([[1, "x"], [2, "y"]], j.sbuf.to_a.sort)

    j.res_approx <+ [[2, "y", "foo"]]
    2.times { j. tick }
    assert_equal([["bar"], ["foo"]], j.node.to_a.sort)
    assert_equal([[1, "x"]], j.sbuf.to_a.sort)

    j.seal_sbuf <+ [["..."]]
    2.times { j. tick }
    assert_equal([["bar"]], j.node.to_a.sort)
    assert_equal([[1, "x"]], j.sbuf.to_a.sort)

    j.res_approx <+ [[1, "x", "bar"]]
    2.times { j. tick }
    assert_equal([], j.node.to_a.sort)
    assert_equal([], j.sbuf.to_a.sort)
  end
end
