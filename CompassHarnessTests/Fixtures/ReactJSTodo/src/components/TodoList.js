import React from "react";
import TodoItem from "./TodoItem";

export default function TodoList({ todos, onToggle, onDelete }) {
  if (todos.length === 0) {
    return <p className="empty">Nothing to do. Add a task above!</p>;
  }
  return (
    <ul className="todo-list">
      {todos.map((todo) => (
        <TodoItem key={todo.id} todo={todo} onToggle={onToggle} onDelete={onDelete} />
      ))}
    </ul>
  );
}
