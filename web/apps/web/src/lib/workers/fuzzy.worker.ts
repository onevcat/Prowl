self.onmessage = (event: MessageEvent<{ query: string; items: string[] }>) => {
  const query = event.data.query.toLowerCase();
  self.postMessage(event.data.items.filter((item) => item.toLowerCase().includes(query)));
};
