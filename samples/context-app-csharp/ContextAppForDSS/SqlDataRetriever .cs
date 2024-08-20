using ContextualDataIngestor;
using System;
using System.Data.SqlClient;
using System.Threading.Tasks;


namespace ContextualDataIngestor
{
    internal class SqlDataRetriever : IDataRetriever
    {
        private readonly string _connectionString;

        public SqlDataRetriever(string connectionString)
        {
            _connectionString = connectionString + ";Integrated Security=True;";
        }

        public async Task<string> RetrieveDataAsync()
        {

            throw new NotImplementedException();
        }



        public void Dispose()
        {
            // No resources to dispose as of now
        }
    }
}