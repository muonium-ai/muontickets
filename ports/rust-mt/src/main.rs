use clap::{Parser, Subcommand};

#[derive(Parser, Debug)]
#[command(name = "mt")]
#[command(about = "MuonTickets CLI port (Rust scaffold)")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Init,
    New {
        title: String,
    },
    Ls,
    Show {
        id: String,
    },
    Pick {
        #[arg(long)]
        owner: String,
    },
    Claim {
        id: String,
        #[arg(long)]
        owner: String,
    },
    Comment {
        id: String,
        text: String,
    },
    SetStatus {
        id: String,
        status: String,
    },
    Done {
        id: String,
    },
    Archive {
        id: String,
    },
    Graph,
    Export,
    Stats,
    Validate,
    Report,
}

fn main() {
    let cli = Cli::parse();
    match cli.command {
        Commands::Init => println!("TODO: init (Rust port)"),
        Commands::New { title } => println!("TODO: new (Rust port): {title}"),
        Commands::Ls => println!("TODO: ls (Rust port)"),
        Commands::Show { id } => println!("TODO: show (Rust port): {id}"),
        Commands::Pick { owner } => println!("TODO: pick (Rust port): owner={owner}"),
        Commands::Claim { id, owner } => println!("TODO: claim (Rust port): {id} owner={owner}"),
        Commands::Comment { id, text } => println!("TODO: comment (Rust port): {id} text={text}"),
        Commands::SetStatus { id, status } => println!("TODO: set-status (Rust port): {id} -> {status}"),
        Commands::Done { id } => println!("TODO: done (Rust port): {id}"),
        Commands::Archive { id } => println!("TODO: archive (Rust port): {id}"),
        Commands::Graph => println!("TODO: graph (Rust port)"),
        Commands::Export => println!("TODO: export (Rust port)"),
        Commands::Stats => println!("TODO: stats (Rust port)"),
        Commands::Validate => println!("TODO: validate (Rust port)"),
        Commands::Report => println!("TODO: report (Rust port)"),
    }
}
