import React from "react";

export default function TodoItem({ todo, onToggle, onDelete }) {
  return (
    <li className={todo.done ? "todo done" : "todo"}>
      <input type="checkbox" checked={todo.done} onChange={() => onToggle(todo.id)} />
      <span className="text">{todo.text}</span>
      <button className="delete" onClick={() => onDelete(todo.id)}>
        Delete
      </button>
    </li>
  );
}
