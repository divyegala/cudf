/*
 * Copyright (c) 2021-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "groupby_test_util.hpp"

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/iterator_utilities.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/concatenate.hpp>
#include <cudf/detail/aggregation/aggregation.hpp>
#include <cudf/table/experimental/row_operators.cuh>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/default_stream.hpp>

#include <rmm/exec_policy.hpp>

#include <thrust/iterator/counting_iterator.h>
#include <thrust/logical.h>

#include <vector>

namespace cudf {
namespace test {

template <typename V>
struct groupby_lists_test : public cudf::test::BaseFixture {
};

TYPED_TEST_SUITE(groupby_lists_test, cudf::test::FixedWidthTypes);

using namespace cudf::test::iterators;

using R = cudf::detail::target_type_t<int32_t, aggregation::SUM>;  // Type of aggregation result.
using strings = strings_column_wrapper;
using structs = structs_column_wrapper;

template <typename T>
using fwcw = cudf::test::fixed_width_column_wrapper<T>;

template <typename T>
using lcw = cudf::test::lists_column_wrapper<T, int32_t>;

namespace {
static constexpr auto null = -1;

// Checking with a single aggregation, and aggregation column.
// This test is orthogonal to the aggregation type; it focuses on testing the grouping
// with LISTS keys.
auto sum_agg() { return cudf::make_sum_aggregation<groupby_aggregation>(); }

inline void test_hash_based_sum_agg(column_view const& keys,
                                    column_view const& values,
                                    column_view const& expect_keys,
                                    column_view const& expect_vals)
{
  auto const sort_order  = sorted_order(table_view{{expect_keys}}, {}, {null_order::AFTER});
  auto const sorted_expect_keys = gather(table_view{{expect_keys}}, *sort_order);
  auto const sorted_expect_vals = gather(table_view{{expect_vals}}, *sort_order);

  test_single_agg(keys,
    values,
    sorted_expect_keys->view().column(0),
    sorted_expect_vals->view().column(0),
    sum_agg(),
    force_use_sort_impl::NO,
    null_policy::INCLUDE);
}

void test_sort_based_sum_agg(column_view const& keys,
                             column_view const& values,
                             column_view const& expect_keys,
                             column_view const& expect_vals)
{
  test_single_agg(keys,
                  values,
                  expect_keys,
                  expect_vals,
                  sum_agg(),
                  force_use_sort_impl::YES,
                  null_policy::INCLUDE);
}

void test_sum_agg(column_view const& keys,
                  column_view const& values,
                  column_view const& expected_keys,
                  column_view const& expected_values)
{
  test_sort_based_sum_agg(keys, values, expected_keys, expected_values);
  test_hash_based_sum_agg(keys, values, expected_keys, expected_values);
}
}  // namespace

TYPED_TEST(groupby_lists_test, basic)
{
  if (std::is_same_v<TypeParam, bool>) { return; }

  // clang-format off
  auto keys   = lcw<TypeParam> { {1,1}, {2,2}, {3,3}, {1,1}, {2,2} };
  auto values = fwcw<int32_t>  {    0,     1,     2,     3,     4  };

  auto expected_keys   = lcw<TypeParam> { {1,1}, {2,2}, {3,3} };
  auto expected_values = fwcw<R>        {    3,     5,     2  };
  // clang-format on

  test_sum_agg(keys, values, expected_keys, expected_values);
}

TYPED_TEST(groupby_lists_test, all_null_input)
{
  // clang-format off
  auto keys   = lcw<TypeParam> { {{1,1}, {2,2}, {3,3}, {1,1}, {2,2}}, all_nulls()};
  auto values = fwcw<int32_t>  {     0,     1,     2,     3,     4 };

  auto expected_keys   = lcw<TypeParam> { {{null,null}}, all_nulls()};
  auto expected_values = fwcw<R>        {          10 };
  // clang-format on

  test_sum_agg(keys, values, expected_keys, expected_values);
}

TYPED_TEST(groupby_lists_test, lists_with_nulls)
{
  // clang-format off
  auto keys   = lcw<TypeParam> { {{1,1}, {2,2}, {3,3}, {1,1}, {2,2}}, nulls_at({1,2,4})};
  auto values = fwcw<int32_t>  {     0,     1,     2,     3,     4 };

  auto expected_keys   = lcw<TypeParam> { {{null,null}, {1,1}}, null_at(0)};
  auto expected_values = fwcw<R>        {           7,     3 };
  // clang-format on

  test_sum_agg(keys, values, expected_keys, expected_values);
}

TYPED_TEST(groupby_lists_test, lists_with_null_elements)
{
  auto keys =
    lcw<TypeParam>{{lcw<TypeParam>{{{1, 2, 3}, {}, {4, 5}, {}, {6, 0}}, nulls_at({1, 3})},
                    lcw<TypeParam>{{{1, 2, 3}, {}, {4, 5}, {}, {6, 0}}, nulls_at({1, 3})},
                    lcw<TypeParam>{{{1, 2, 3}, {}, {4, 5}, {}, {6, 0}}, nulls_at({1, 3})},
                    lcw<TypeParam>{{{1, 2, 3}, {}, {4, 5}, {}, {6, 0}}, nulls_at({1, 3})}},
                   nulls_at({2, 3})};
  auto values = fwcw<int32_t>{1, 2, 4, 5};

  auto expected_keys = lcw<TypeParam>{
    {{}, lcw<TypeParam>{{{1, 2, 3}, {}, {4, 5}, {}, {6, 0}}, nulls_at({1, 3})}}, null_at(0)};
  auto expected_values = fwcw<R>{9, 3};

  test_sum_agg(keys, values, expected_keys, expected_values);
}
}  // namespace test
}  // namespace cudf
