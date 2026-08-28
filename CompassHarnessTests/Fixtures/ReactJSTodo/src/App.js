import React, { useState } from "react";
import TodoList from "./components/TodoList";
import AddTodo from "./components/AddTodo";
import { loadTodos, saveTodos } from "./utils/storage";

export default function App() {
  const [todos, setTodos] = useState(loadTodos());

  const addTodo = (text) => {
    const todo = { id: Date.now(), text, done: false };
    const next = [...todos, todo];
    setTodos(next);
    saveTodos(next);
  };

  const toggleTodo = (id) => {
    const next = todos.map((t) => (t.id === id ? { ...t, done: !t.done } : t));
    setTodos(next);
    saveTodos(next);
  };

  const deleteTodo = (id) => {
    const next = todos.filter((t) => t.id !== id);
    setTodos(next);
    saveTodos(next);
  };

  return (
    <div className="app">
      <h1>ReactJS Todo</h1>
      <AddTodo onAdd={addTodo} />
      <TodoList todos={todos} onToggle={toggleTodo} onDelete={deleteTodo} />
    </div>
  );
}
