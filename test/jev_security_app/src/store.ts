export const db = {
  async query(statement: string, parameters: unknown[] = []) {
    return { statement, parameters };
  },
};
