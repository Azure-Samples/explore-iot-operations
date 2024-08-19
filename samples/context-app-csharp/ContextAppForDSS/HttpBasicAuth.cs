namespace ContextualDataIngestor
{
    public class HttpBasicAuth : IAuthStrategy
    {
        //        private readonly string _username;
        //        private readonly string _password;

        //        public BasicAuthStrategy(string username, string password)
        //        {
        //            _username = username ?? throw new ArgumentNullException(nameof(username));
        //            _password = password ?? throw new ArgumentNullException(nameof(password));
        //        }
        public required string Username { get; set; }
        public required string Password { get; set; }
    }
}
