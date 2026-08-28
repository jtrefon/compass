import React, { useState } from "react";

export default function AddTodo({ onAdd }) {
  const [text, setText] = useState("");

  const submit = (e) => {
    e.preventDefault();
    const trimmed = text.trim();
    if (!trimmed) return;
    onAdd(trimmed);
    setText("");
  };

  return (
    <form className="add-todo" onSubmit={submit}>
      <input value={text} onChange={(e) => setText(e.target.value)} placeholder="What needs doing?" />
      <button type="submit">Add</button>
    </form>
  );
}
