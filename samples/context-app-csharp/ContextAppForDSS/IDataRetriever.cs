using ContextualDataIngestor;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace ContextualDataIngestor
{
    internal interface IDataRetriever : IDisposable
    {
        Task<string> RetrieveDataAsync();
    }
}
