// JSONPath RFC 9535 专项测试：过滤器逻辑组合、双查询比较、标准函数、混合并集、递归下降变体。
package rawprism.test

import rawprism.object.*
import rawprism.parse.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/// RFC 9535 经典 store/ 书店语料。
internal func rfcStoreRoot(): Obj {
    let text = """
{"store": {"book": [
  {"category": "reference", "author": "Nigel Rees", "title": "Sayings", "price": 8.95},
  {"category": "fiction", "author": "Evelyn Waugh", "title": "Sword of Honour", "price": 12.99},
  {"category": "fiction", "author": "Herman Melville", "title": "Moby Dick", "isbn": "0-553-21311-3", "price": 8.99},
  {"category": "fiction", "author": "J. R. R. Tolkien", "title": "The Lord of the Rings", "isbn": "0-395-19395-8", "price": 22.99}
 ],
 "bicycle": {"color": "red", "price": 19.95}},
 "expensive": 10}
"""
    parseJson(text.toArray()).value.getOrThrow()
}

@Test
func jsonPathLogicalAndOr(): Unit {
    // 逻辑 && 与 ||（RFC 9535 操作符；and/or 宽容别名）
    let root = rfcStoreRoot()
    // 价格 < 10 且存在 isbn：8.99（Moby Dick）一本
    let both = jsonPath(root, "$.store.book[?(@.price < 10 && @.isbn)]")
    @Assert(both.size == 1)
    // 分类为 fiction 或价格 > 20
    let either = jsonPath(root, "$.store.book[?(@.category=='fiction' || @.price > 20)]")
    @Assert(either.size == 3)
    // 文字别名形式（与 && 语义一致）
    let wordForm = jsonPath(root, "$.store.book[?(@.price < 10 and @.isbn)]")
    @Assert(wordForm.size == 1)
}

@Test
func jsonPathLogicalNotAndParens(): Unit {
    let root = rfcStoreRoot()
    // 非
    let notCheap = jsonPath(root, "$.store.book[?(!@.isbn)]")
    @Assert(notCheap.size == 2)
    // 括号分组
    let grouped = jsonPath(root, "$.store.book[?(!(@.price < 10) && @.category=='fiction')]")
    @Assert(grouped.size == 2)
    // 双重否定
    let dbl = jsonPath(root, "$.store.book[?(!(!@.isbn))]")
    @Assert(dbl.size == 2)
}

@Test
func jsonPathSingularQueryComparison(): Unit {
    // 双单一查询比较：@ 与 $ 两侧
    let root = rfcStoreRoot()
    // 书价高于全场阈值 expensive=10
    let above = jsonPath(root, "$.store.book[?(@.price > $.expensive)]")
    @Assert(above.size == 2)
    // 同节点自比较恒等
    let selfEq = jsonPath(root, "$.store.book[?(@.price == @.price)]")
    @Assert(selfEq.size == 4)
    // 不同键比较：category 与 title（均为字符串，互不相等）
    let diff = jsonPath(root, "$.store.book[?(@.category == @.title)]")
    @Assert(diff.size == 0)
}

@Test
func jsonPathFunctionLengthCount(): Unit {
    let root = rfcStoreRoot()
    // length()：作者名长度 > 12
    let longNames = jsonPath(root, "$.store.book[?length(@.author) > 12]")
    @Assert(longNames.size == 2)
    // count()：非单一查询作参数
    let cnt = jsonPath(root, "$.store.book[?(count(@..*) > 0)]")
    @Assert(cnt.size == 4)
    // length() 用于字符串字面量
    let lit = jsonPath(root, "$.store.book[?(length('ab') == 2)]")
    @Assert(lit.size == 4)
}

@Test
func jsonPathFunctionMatchSearch(): Unit {
    let root = rfcStoreRoot()
    // match()：全匹配
    let full = jsonPath(root, "$.store.book[?match(@.author, 'J\\\\. R\\\\. R\\\\. Tolkien')]")
    @Assert(full.size == 1)
    @Assert(full[0].get("author").getOrThrow().asText() == Some("J. R. R. Tolkien"))
    // search()：子串搜索
    let part = jsonPath(root, "$.store.book[?search(@.title, 'Rings')]")
    @Assert(part.size == 1)
    let none = jsonPath(root, "$.store.book[?search(@.title, 'ZZZ')]")
    @Assert(none.size == 0)
}

@Test
func jsonPathFunctionValue(): Unit {
    let root = rfcStoreRoot()
    // value()：把单一查询结果取为字面量参与比较
    let v = jsonPath(root, "$.store.book[?(@.category == value('fiction'))]")
    @Assert(v.size == 3)
}

@Test
func jsonPathMixedUnion(): Unit {
    let root = rfcStoreRoot()
    // 混合并集：名称与下标可混用（RFC 9535 段内并集）
    let books = jsonPath(root, "$.store['book',0]")
    // 名称命中序列本身；下标 0 对映射无命中（RFC 9535：不匹配的选择器产出 Nothing）
    @Assert(books.size == 1)
    let seq = rfcStoreRoot()
    let arr = parseJson("[10,20,30]".toArray()).value.getOrThrow()
    let mixed = jsonPath(arr, "$[1,2]")
    @Assert(mixed.size == 2)
    let _ = seq
}

@Test
func jsonPathRecursiveVariants(): Unit {
    let root = rfcStoreRoot()
    // ..name：任意深度的键
    let prices = jsonPath(root, "$..price")
    @Assert(prices.size == 5)  // 4 本书 + 自行车
    // ..*：全部后代
    let all = jsonPath(root, "$..*")
    @Assert(all.size > 10)
    // ..[?(...)]：对每个后代应用过滤器
    let cheapAnywhere = jsonPath(root, "$..[?(@.price < 9)]")
    @Assert(cheapAnywhere.size == 2)
}

@Test
func jsonPathSliceNegativeStep(): Unit {
    let arr = parseJson("[0,1,2,3,4,5]".toArray()).value.getOrThrow()
    @Assert(jsonPath(arr, "$[::2]").size == 3)
    @Assert(jsonPath(arr, "$[::-1]").size == 6)
    @Assert(jsonPath(arr, "$[4:1:-1]").size == 3)
    @Assert(jsonPath(arr, "$[-2:]").size == 2)
}

@Test
func jsonPathTypeMismatchComparisons(): Unit {
    // RFC 9535：有序比较类型不匹配为假；Nothing 仅与 Nothing 相等
    let root = parseJson("{\"a\": [{\"x\": 1}, {\"x\": \"s\"}, {}]}".toArray()).value.getOrThrow()
    // 数字与字符串有序比较为假
    @Assert(jsonPath(root, "$.a[?(@.x > 0)]").size == 1)
    // 缺失键与 null 不相等（Nothing != null）
    @Assert(jsonPath(root, "$.a[?(@.x == null)]").size == 0)
    // 缺失键存在性为假
    @Assert(jsonPath(root, "$.a[?(@.missing)]").size == 0)
    // 缺失键与字面量相等为假
    @Assert(jsonPath(root, "$.a[?(@.missing == 1)]").size == 0)
}

@Test
func jsonPathStringEscapesInFilter(): Unit {
    // 过滤器内字符串字面量的转义与双引号形式
    let root = parseJson("{\"a\": [{\"s\": \"it's\"}, {\"s\": \"q\\\"x\"}]}".toArray()).value.getOrThrow()
    // 单引号 '' 转义
    @Assert(jsonPath(root, "$.a[?(@.s == 'it''s')]").size == 1)
    // 双引号字符串
    @Assert(jsonPath(root, "$.a[?(@.s == \"it's\")]").size == 1)
}
