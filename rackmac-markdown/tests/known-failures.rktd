;; Spec examples (CommonMark 0.31.2) the parser does not yet match exactly, with the reason.
;; Read by tests/spec-test.rkt: every example NOT listed here must match exactly, and a listed
;; example that starts passing must be removed. Design §5: the v0.4 gate is this list being empty.
;; Format: (example-number "section" "reason")
(
 (259 "List items"
      "block phase (#317): list item inside two block quotes whose first line has leading spaces before the `>`s; the continuation line `>>     two` is taken as indented code instead of the item's second paragraph (column accounting across the quote markers' optional spaces)")
 (260 "List items"
      "block phase (#317): `  >  > two` after a blank `>>` line is taken as a lazy continuation of the list item's paragraph instead of closing the list (the blank line inside the nested quotes is not seen by the list item)")
)
